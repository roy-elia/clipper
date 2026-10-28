import SwiftUI
import DropCore
import UniformTypeIdentifiers

@MainActor
final class ShelfModel: ObservableObject {
    @Published var query = ""
    @Published var kind: ClipKind?
    @Published var board: String?          // nil = History
    @Published var app: String?            // source-app filter
    @Published var dateRange: DateRange?   // date filter
    @Published var picks = false           // show suggestions for targetApp instead of history
    @Published var targetApp: String?      // the app a paste would go into
    var log = PasteLog()
    @Published var apps: [String] = []
    @Published var selection = 0
    @Published var focusTick = 0           // bumped each time the shelf opens so search regains focus
    @Published var searchTick = 0          // bumped by ⌘F, which also opens the collapsed search field
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
    @Published var marked: [UUID] = []      // extra cards picked with ⌘-click, in the order picked
    @Published var syncing = false
    @Published var diagnosing = false
    @Published var namingBoard = false     // the inline new-pinboard field has the keyboard
    var finishNamingBoard: ((Bool) -> Void)?   // true creates the pinboard, false cancels
    @Published var lastSynced: Date?
    var onPickMany: (([ClipItem], Bool) -> Void)?
    var onDeleted: ((Int) -> Void)?
    var onWritingTools: ((ClipItem) -> Void)?
    var onSyncNow: (() -> Void)?
    var onOpen: ((ClipItem, URL?) -> Void)?        // open a file or link, optionally with a chosen app
    var onReveal: ((ClipItem) -> Void)?
    var onCopyPlain: ((ClipItem) -> Void)?
    var onEditBoard: ((String) -> Void)?
    var confirmPin: ((Int, String) -> Bool)?
    func selectAll() { marked = items.map(\.id) }
    func deselectAll() { marked = [] }
    /// The cards a paste or delete acts on: the ⌘-click set when there is one, else the selected card.
    var targets: [ClipItem] {
        let picked = marked.compactMap { id in items.first { $0.id == id } }
        return picked.isEmpty ? (selected.map { [$0] } ?? []) : picked
    }
    func toggleMark(_ item: ClipItem) {
        if marked.isEmpty, let s = selected, s.id != item.id { marked = [s.id] }
        if let i = marked.firstIndex(of: item.id) { marked.remove(at: i) } else { marked.append(item.id) }
        if let i = items.firstIndex(where: { $0.id == item.id }) { selection = i }
    }
    func pickTargets(plain: Bool) {
        let t = targets
        if t.count > 1 { onPickMany?(t, plain) } else if let one = t.first { onPick?(one, plain) }
    }
    func deleteTargets() {
        let t = targets; guard !t.isEmpty else { return }
        lastDeletedBatch = t
        for i in t { store.delete(i.id); stack.remove(i.id) }
        lastDeleted = t.first; marked = []; refresh(); onDeleted?(t.count)
    }
    var lastDeletedBatch: [ClipItem] = []
    /// Removes every unpinned screenshot; ⌘Z puts them back, like any delete. Returns how many went.
    @discardableResult func clearScreenshots() -> Int { removeBatch(store.deleteScreenshots()) }
    /// Finishes a bulk delete the store already did: the stack, marks and undo follow it. Returns how many went.
    @discardableResult func removeBatch(_ gone: [ClipItem]) -> Int {
        guard !gone.isEmpty else { return 0 }
        let ids = Set(gone.map(\.id))
        for i in gone { stack.remove(i.id) }
        lastDeletedBatch = gone; lastDeleted = gone.first; marked.removeAll { ids.contains($0) }; refresh()
        return gone.count
    }

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
            if let r = dateRange { items = items.filter { r.contains($0.createdAt) } }
        }
        boards = store.pinboards(); apps = store.apps()
        selection = items.isEmpty ? 0 : min(selection, items.count - 1)
        marked.removeAll { id in !items.contains { $0.id == id } }
    }

    func move(_ delta: Int) { guard !items.isEmpty else { return }; selection = min(max(selection + delta, 0), items.count - 1) }
    var selected: ClipItem? { items.indices.contains(selection) ? items[selection] : nil }
    func pickSelected(plain: Bool) { if !namingBoard, let i = selected { onPick?(i, plain) } }
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
    @Published var lastDeleted: ClipItem?
    func delete(_ item: ClipItem) {
        lastDeleted = item; lastDeletedBatch = [item]; store.delete(item.id); stack.remove(item.id)
        marked.removeAll { $0 == item.id }; refresh(); onDeleted?(1)
    }
    /// ⌘Z after a delete puts the clip (or the whole deleted selection) back.
    @discardableResult func undoDelete() -> Bool {
        guard !lastDeletedBatch.isEmpty else { return false }
        for i in lastDeletedBatch { store.restore(i) }
        lastDeleted = nil; lastDeletedBatch = []; refresh(); return true
    }
    /// An empty name makes "Untitled" (or "Untitled 2", …).
    func addBoard(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? store.freeBoardName() : name.trimmingCharacters(in: .whitespaces)
        if store.createPinboard(n) { picks = false; board = n; refresh() }
    }
    func renameBoard(_ old: String, _ new: String) { if store.renamePinboard(old, to: new) { board = new; refresh() } }
    func boardColor(_ name: String) -> Color { Color(hex: store.boardColor(name)) ?? .red }
    func deleteBoard(_ name: String) { store.deletePinboard(name); if board == name { board = nil }; refresh() }
    func updateSettings(_ f: (inout AppSettings) -> Void) { f(&settings); store.capacity = settings.historyCapacity; onSettingsChanged?() }
}

/// Commands from the shelf's ⋯ menu, handled by the app.
enum ShelfCommand { case about, newClip, settings, gettingStarted, shortcuts, pause(TimeInterval?), resume, clear, clearScreenshots, clearImages, quit, importFromDevice, startDiagnostics, stopDiagnostics }

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @State private var newBoard = ""
    @State private var adding = false
    @State private var dropTargeted = false
    @State private var filtering = false
    @State private var dropBoard: String?
    @FocusState private var boardFieldFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var searchHover = false
    @State private var searchPinned = false

    /// The drop target and naming field can be preset so snapshots show those states.
    init(model: ShelfModel, dropBoard: String? = nil, adding: Bool = false) {
        self.model = model; _dropBoard = State(initialValue: dropBoard); _adding = State(initialValue: adding)
    }

    static let cardSize = CGSize(width: 234, height: 234)
    static let height: CGFloat = 332

    var body: some View {
        VStack(spacing: 8) {
            bar
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: dropTargeted ? "arrow.down.circle" : emptySymbol).font(.title)
                    Text(emptyTitle).font(.title2.weight(.semibold))
                    Text(emptyBody).font(.callout).foregroundStyle(Palette.glassLabel2).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .foregroundStyle(Palette.glassLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 18) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                                Card(item: item, number: model.modifierHeld && idx < 9 ? idx + 1 : nil,
                                     selected: model.marked.isEmpty ? idx == model.selection : model.marked.contains(item.id),
                                     marked: model.marked.contains(item.id), active: model.isKey,
                                     quickSymbol: model.settings.quickModifier.symbol,
                                     boardColor: item.pinboard.map { model.boardColor($0) },
                                     onDelete: { model.delete(item) })
                                    .id(item.id)
                                    .onTapGesture {
                                        let flags = NSEvent.modifierFlags
                                        if flags.contains(.command) { model.toggleMark(item); return }
                                        if !model.marked.isEmpty && model.marked.contains(item.id) { model.pickTargets(plain: flags.contains(.shift)); return }
                                        model.marked = []; model.selection = idx; model.onPick?(item, flags.contains(.shift))
                                    }
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
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.accent.opacity(0.14))
                    .overlay {
                        Label("Drop to add to \(model.board ?? "Clipboard")", systemImage: "tray.and.arrow.down")
                            .font(.body.weight(.medium)).foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 16).frame(height: 34).background(Palette.accentFill, in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $dropTargeted) { model.onDrop?($0) ?? false }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusTick) { searchFocused = true }
        .onChange(of: model.searchTick) { searchPinned = true }
        .onChange(of: model.query) { model.refresh() }
        .onChange(of: model.kind) { model.refresh() }
        .onChange(of: model.board) { model.refresh() }
        .onChange(of: model.app) { model.refresh() }
        .onChange(of: model.dateRange) { model.refresh() }
    }

    // MARK: empty states

    var emptySymbol: String {
        if model.board != nil && model.query.isEmpty { return "tray" }
        if !model.query.isEmpty { return "magnifyingglass" }
        return model.picks ? "sparkles" : "doc.on.clipboard"
    }
    var emptyTitle: String {
        if model.board != nil && model.query.isEmpty { return "Pinboard is empty" }
        if !model.query.isEmpty { return "No clips match “\(model.query)”" }
        return model.picks ? "No suggestions yet" : "Nothing copied yet"
    }
    var emptyBody: String {
        if model.board != nil && model.query.isEmpty { return "Drag a card onto this pinboard's tab, or right-click a card and choose Pin." }
        if !model.query.isEmpty { return "Try fewer words, or clear the filters." }
        return model.picks ? "Suggestions appear as you copy and switch apps." : "Copy anything and it lands here, or drop images, files or text on the shelf."
    }

    // MARK: control row

    var bar: some View {
        ZStack {
            HStack(spacing: 6) {
                iconButton(model.picks ? "sparkles" : "sparkles", label: "Suggestions", selected: model.picks) {
                    model.picks.toggle(); if model.picks { model.board = nil }; model.refresh()
                }.accessibilityIdentifier("shelf.tab.Picks")
                if model.settings.iCloudSync {
                    SyncButton(syncing: model.syncing, last: model.lastSynced) { model.onSyncNow?() }
                }
                if model.marked.count > 1 {
                    // A filled capsule: accent text straight on glass is 2.1:1 over a dark desktop.
                    Text("\(model.marked.count) selected").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Palette.accentFill, in: Capsule())
                        .accessibilityIdentifier("shelf.selectedCount")
                }
                Spacer()
                if !model.stack.isEmpty {
                    Label("\(model.stack.items.count) in stack", systemImage: "square.stack.3d.up").font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.glassLabel).padding(.horizontal, 10).frame(height: 24).background(.quaternary, in: Capsule())
                }
                Text(model.items.count == 1 ? "1 clip" : "\(model.items.count) clips").font(.subheadline.weight(.medium)).foregroundStyle(Palette.glassLabel2)
                    .accessibilityIdentifier("shelf.count")
                iconButton("trash", label: "Clear history") { model.onClear?() }.accessibilityIdentifier("shelf.clear")
                moreMenu
            }
            HStack(spacing: 6) {
                searchField
                iconButton("line.3.horizontal.decrease", label: "Filter", selected: filterCount > 0) { filtering.toggle() }
                    .overlay(alignment: .topTrailing) {
                        if filterCount > 0 {
                            // Ink, not accent: it stands apart from the selected (accent) button without a keyline drawn on glass.
                            Text("\(filterCount)").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.inkOn)
                                .frame(minWidth: 14, minHeight: 14).background(Palette.ink, in: Capsule()).offset(x: 3, y: -3)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("shelf.filter")
                    .popover(isPresented: $filtering, arrowEdge: .top) { FilterPopover(model: model) }
                tab("Clipboard", nil, symbol: "clock.arrow.circlepath")
                ForEach(model.boards, id: \.self) { b in
                    tab(b, b, dot: model.boardColor(b), targeted: dropBoard == b)
                        .onDrop(of: [.clipperClip], isTargeted: Binding(get: { dropBoard == b }, set: { dropBoard = $0 ? b : (dropBoard == b ? nil : dropBoard) })) { providers in
                            pinDropped(providers, to: b)
                        }
                        .contextMenu {
                        Button("Edit Pinboard…") { model.onEditBoard?(b) }
                        Button("Rename…") { model.onRenameBoard?(b) }
                        Menu("Colour") {
                            ForEach(HistoryStore.boardPalette, id: \.self) { hex in
                                Toggle(isOn: Binding(get: { model.store.boardColor(b) == hex },
                                                     set: { _ in model.store.setBoardColor(b, hex); model.refresh() })) {
                                    Label { Text(colorName(hex)) } icon: { Image(nsImage: Self.menuDot(hex)) }
                                }
                            }
                        }
                        Divider()
                        Button("Delete Pinboard", role: .destructive) { model.deleteBoard(b) }
                    }
                }
                if adding {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: HistoryStore.boardPalette[model.boards.count % HistoryStore.boardPalette.count]) ?? .red).frame(width: 9, height: 9)
                        TextField("Pinboard name", text: $newBoard).textFieldStyle(.plain).frame(width: 120)
                            .focused($boardFieldFocused)
                            .accessibilityIdentifier("shelf.newBoardField")
                            .onSubmit { model.addBoard(newBoard); newBoard = ""; adding = false }
                            .onExitCommand { newBoard = ""; adding = false }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                    .onAppear {
                        model.finishNamingBoard = { create in if create { model.addBoard(newBoard) }; newBoard = ""; adding = false }
                        model.namingBoard = true; searchFocused = false; DispatchQueue.main.async { boardFieldFocused = true }
                    }
                    .onDisappear { model.namingBoard = false; model.finishNamingBoard = nil; searchFocused = true }
                } else {
                    iconButton("plus", label: "New pinboard") { adding = true }.accessibilityIdentifier("shelf.addBoard")
                }
            }
        }
        .padding(.horizontal, 16).frame(height: 44)
    }

    /// A magnifier that widens into a field on hover or click, and stays open while it holds text. The field keeps
    /// keyboard focus while collapsed, so typing on an open shelf still searches (and opens it).
    /// How many filters (type, app, date) are hiding clips.
    var filterCount: Int { [model.kind != nil, model.app != nil, model.dateRange != nil].filter { $0 }.count }

    var searchField: some View {
        let open = searchHover || searchPinned || !model.query.isEmpty
        return HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(open ? Palette.glassLabel2 : Palette.glassLabel)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { model.pickSelected(plain: false) }
                .accessibilityIdentifier("shelf.search")
                .frame(width: open ? nil : 0).opacity(open ? 1 : 0)
        }
        .padding(.horizontal, open ? 10 : 6)
        .frame(width: open ? 200 : 28, height: 28)
        .background(open ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
        .contentShape(Capsule())
        .onHover { searchHover = $0; if !$0 && model.query.isEmpty { searchPinned = false } }
        .onTapGesture { searchPinned = true; searchFocused = true }
        .onChange(of: model.query) { if model.query.isEmpty && !searchHover { searchPinned = false } }
        .help("Search clips")
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18), value: open)
    }

    var moreMenu: some View {
        Menu {
            Button { model.onCommand?(.about) } label: { Label("About Clipper", systemImage: "info.circle") }
            Divider()
            Button { model.onCommand?(.newClip) } label: { Label("New Clip…", systemImage: "square.and.pencil") }.keyboardShortcut("n")
            Button { model.onCommand?(.settings) } label: { Label("Settings…", systemImage: "gearshape") }.keyboardShortcut(",")
            Divider()
            Button { model.selectAll() } label: { Label("Select All", systemImage: "checkmark.circle") }
            if !model.marked.isEmpty { Button { model.deselectAll() } label: { Label("Deselect All", systemImage: "circle") } }
            Button { model.onCommand?(.importFromDevice) } label: { Label("Import from iPhone…", systemImage: "iphone") }
            Menu {
                Button("Getting Started") { model.onCommand?(.gettingStarted) }
                Button("Keyboard Shortcuts") { model.onCommand?(.shortcuts) }
                Divider()
                if model.diagnosing { Button("Stop and Copy Logs") { model.onCommand?(.stopDiagnostics) } }
                else { Button("Start Diagnostics") { model.onCommand?(.startDiagnostics) } }
            } label: { Label("Help", systemImage: "questionmark.circle") }
            Divider()
            if let p = model.pausedUntil {
                Button { model.onCommand?(.resume) } label: { Label("Resume Capture (\(p))", systemImage: "play.circle") }
            } else {
                Menu {
                    Button("Until I Resume") { model.onCommand?(.pause(nil)) }
                    Divider()
                    ForEach(CapturePause.durations, id: \.1) { d in Button("For \(d.0)") { model.onCommand?(.pause(d.1)) } }
                } label: { Label("Pause Capture", systemImage: "pause.circle") }
            }
            Button { model.onCommand?(.clearScreenshots) } label: { Label("Clear Screenshots", systemImage: "camera.viewfinder") }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
            Button { model.onCommand?(.clearImages) } label: { Label("Clear Images", systemImage: "photo.on.rectangle") }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button { model.onCommand?(.clear) } label: { Label("Clear History…", systemImage: "trash") }
            Divider()
            Button { model.onCommand?(.quit) } label: { Label("Quit Clipper", systemImage: "xmark.square") }.keyboardShortcut("q")
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        // Monochrome like the other bar glyphs: accent on glass is kept for the selected state.
        .tint(Palette.glassLabel)
        .accessibilityLabel("More").accessibilityIdentifier("shelf.more")
    }

    func iconButton(_ symbol: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Circle()) }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Palette.onAccent : Palette.glassLabel)
            .background(selected ? AnyShapeStyle(Palette.accentFill) : AnyShapeStyle(.clear), in: Circle())
            .help(label).accessibilityLabel(label)
    }

    /// `targeted` while a card is dragged over it: an accent fill, since outlines don't go on glass.
    func tab(_ title: String, _ b: String?, symbol: String? = nil, dot: Color? = nil, targeted: Bool = false) -> some View {
        let on = !model.picks && model.board == b
        return Button { model.picks = false; model.board = b; model.refresh() } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
                Text(title)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(targeted ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
            .background(targeted ? AnyShapeStyle(Palette.accentFill) : on ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).font(.callout.weight(on ? .semibold : .regular))
        .accessibilityIdentifier("shelf.tab.\(b == nil ? "History" : title)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A board-colour dot for menus. Not a template image, so the menu keeps its colour instead of tinting every dot alike.
    static func menuDot(_ hex: String) -> NSImage {
        let color = NSColor(Color(hex: hex) ?? .gray)
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill(); return true
        }
        img.isTemplate = false
        return img
    }

    func colorName(_ hex: String) -> String {
        ["#FF5F57": "Red", "#FFB340": "Orange", "#FFD84D": "Yellow", "#34C759": "Green", "#30B0C7": "Teal", "#3D7BFF": "Blue", "#AF52DE": "Purple", "#FF6FAF": "Pink"][hex] ?? hex
    }

    /// What leaves the shelf when a card is dragged: the image, the files, or the text.
    func provider(for item: ClipItem) -> NSItemProvider {
        let p: NSItemProvider
        if item.isSecret { p = NSItemProvider() }
        else if let urls = item.fileURLs, let u = urls.first.flatMap({ URL(string: $0) }) { p = NSItemProvider(contentsOf: u) ?? NSItemProvider() }
        else if let d = item.data, let img = NSImage(data: d) { p = NSItemProvider(object: img) }
        else { p = NSItemProvider(object: (item.text ?? item.title) as NSString) }
        // Inside the shelf the card also carries its id, so dropping it on a pinboard tab pins it.
        let id = item.id.uuidString
        p.registerDataRepresentation(forTypeIdentifier: UTType.clipperClip.identifier, visibility: .ownProcess) { done in
            done(Data(id.utf8), nil); return nil
        }
        return p
    }

    /// The file or web address a file or link card points at.
    static func target(of item: ClipItem) -> URL? {
        if item.kind == .file { return item.fileURLs?.first.flatMap { URL(string: $0) } }
        if item.kind == .link { return item.text.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        return nil
    }

    func pinDropped(_ providers: [NSItemProvider], to board: String) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.clipperClip.identifier) }) else { return false }
        p.loadDataRepresentation(forTypeIdentifier: UTType.clipperClip.identifier) { data, _ in
            guard let data, let s = String(data: data, encoding: .utf8), let id = UUID(uuidString: s) else { return }
            Task { @MainActor in
                let ids = model.marked.contains(id) ? model.marked : [id]
                if ids.count > 1, model.confirmPin?(ids.count, board) == false { return }
                for i in ids { model.store.setPinboard(board, for: i) }
                model.marked = []; model.refresh()
            }
        }
        return true
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
        if let b = item.pinboard, model.picks || model.board != b {
            Button("Show in \(b)") { model.picks = false; model.board = b; model.refresh() }
            Divider()
        }
        if model.marked.count > 1 && model.marked.contains(item.id) {
            Button("Paste \(model.marked.count) Clips") { model.pickTargets(plain: false) }
            Button("Delete \(model.marked.count) Clips", role: .destructive) { model.deleteTargets() }
            Divider()
        }
        Button("Paste to \(model.targetApp.map(AppInfo.name) ?? "Front App")") { model.onPick?(item, false) }
        Button("Paste as Plain Text") { model.onPick?(item, true) }
        Button("Copy") { model.onCopy?(item) }
        if !item.isSecret, item.text != nil, item.kind != .file { Button("Copy as Plain Text") { model.onCopyPlain?(item) } }
        if !item.isSecret, item.kind == .file || item.kind == .link {
            Divider()
            Button(item.kind == .link ? "Open Link" : "Open") { model.onOpen?(item, nil) }.keyboardShortcut("o")
            if let target = ShelfView.target(of: item) {
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: target).prefix(12)
                if !apps.isEmpty {
                    Menu("Open With") {
                        ForEach(Array(apps), id: \.self) { a in
                            Button(FileManager.default.displayName(atPath: a.path).replacingOccurrences(of: ".app", with: "")) { model.onOpen?(item, a) }
                        }
                    }
                }
            }
            if item.kind == .file { Button("Reveal in Finder") { model.onReveal?(item) }.keyboardShortcut("r", modifiers: [.command, .shift]) }
        }
        Divider()
        if item.fileURLs == nil && !item.isSecret {
            Button("Edit") { model.onEdit?(item) }
            if item.kind == .text { Button("Writing Tools") { model.onWritingTools?(item) } }
        }
        Button("Rename…") { model.onRename?(item) }
        Button("Duplicate") { model.store.duplicate(item.id); model.refresh() }
        Button("Delete", role: .destructive) { model.delete(item) }
        Divider()
        Menu("Pin") {
            ForEach(model.boards, id: \.self) { b in
                Button { model.pin(item, to: b) } label: {
                    Label { Text(b) } icon: { Image(nsImage: Self.menuDot(model.store.boardColor(b))) }
                }
            }
            if item.pinboard != nil { Divider(); Button("Unpin") { model.pin(item, to: nil) } }
        }
        Button("Add to Paste Stack") { model.stack.push(item) }.keyboardShortcut("k")
        if item.isSecret { Button("Not a Secret") { model.store.markSecret(item.id, false); model.refresh() } }
        else if item.kind == .text { Button("Mark as Secret") { model.store.markSecret(item.id); model.refresh() } }
        Divider()
        Button("Preview") { model.onPreview?(item) }
        if !item.isSecret { Button("Share…") { model.onShare?(item) } }
        Divider()
        Button("Select All") { model.selectAll() }
        if !model.marked.isEmpty { Button("Deselect All") { model.deselectAll() } }
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
            section("Date")
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(DateRange.allCases, id: \.self) { r in
                    chip(r.label, symbol: "calendar", on: model.dateRange == r) { model.dateRange = model.dateRange == r ? nil : r }
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
            if model.kind != nil || model.app != nil || model.dateRange != nil {
                Button("Clear Filters") { model.kind = nil; model.app = nil; model.dateRange = nil }.buttonStyle(.link)
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
    var marked = false
    var active = true
    var quickSymbol = "⌘"
    var boardColor: Color? = nil
    var onDelete: (() -> Void)? = nil
    @State private var hovering = false
    @State private var thumb: NSImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // Pinned cards take their pinboard's colour; others the source app's. Shaded until its label reaches 4.5:1.
        let header = Palette.headerFill(boardColor ?? AppInfo.color(item.sourceBundleID))
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
                    Text(Relative.string(from: item.createdAt)).font(.subheadline)
                }
                .foregroundStyle(ink).padding(.leading, 14).padding(.top, 8).padding(.trailing, 60)
            }
            .frame(height: 48, alignment: .top).clipped()
            ZStack(alignment: .bottom) {
                content
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Cards are content, not glass: at 62% a busy desktop pulled footer text below 4.5:1.
            .background(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency || increased ? 1 : 0.9))
        }
        .frame(width: ShelfView.cardSize.width, height: ShelfView.cardSize.height)
        .clipShape(shape)
        .shadow(color: Palette.cardShadow, radius: 6, y: 2)
        .padding(4)
        .overlay {
            // A 3 pt ring outside a 1.5 pt keyline (2 pt with Increase Contrast), hugging the card at 20.5 pt corners.
            if selected {
                ZStack {
                    RoundedRectangle(cornerRadius: 20.5, style: .continuous)
                        .strokeBorder(active ? Palette.accent : Palette.ringInactive, lineWidth: 3)
                    RoundedRectangle(cornerRadius: 17.5, style: .continuous)
                        .strokeBorder(Palette.keyline, lineWidth: increased ? 2 : 1.5).padding(3)
                }
                .padding(-0.5).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            // Marked cards also carry a check, so multi-select doesn't rely on colour alone.
            if marked && !hovering {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.onAccent)
                    .frame(width: 20, height: 20).background(Palette.accentFill, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.keyline, lineWidth: 1.5))
                    .offset(x: -2, y: -2).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if hovering, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20).background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                .buttonStyle(.plain).help("Delete this clip (⌘Z to undo)")
                .accessibilityLabel("Delete clip").accessibilityIdentifier("card.delete")
                .offset(x: -2, y: -2).transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .task(id: item.id) { if item.kind == .file { thumb = await FileThumb.image(for: item) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(item.isSecret ? "hidden secret" : item.title), \(item.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var increased: Bool { contrast == .increased }
    var title: String { item.customTitle ?? (item.isSecret ? "Secret" : item.kind.rawValue.capitalized) }
    var fullBleed: Bool { !item.isSecret && (item.kind == .image || item.kind == .color) }

    /// The centred detail line; colour cards show their sRGB values because the hex is already on the swatch.
    var detail: String {
        guard !item.isSecret, item.kind == .color, let t = item.text, let c = Color(hex: t),
              let ns = NSColor(c).usingColorSpace(.sRGB) else { return item.detail }
        return "sRGB \(Int((ns.redComponent * 255).rounded())) · \(Int((ns.greenComponent * 255).rounded())) · \(Int((ns.blueComponent * 255).rounded()))"
    }

    @ViewBuilder var footer: some View {
        HStack {
            Spacer(minLength: 0)
            if let n = number {
                // While the modifier is held the badge takes the detail's place; ink reads on every card kind.
                Text("\(quickSymbol)\(n)").font(.caption2.monospaced().weight(.semibold)).foregroundStyle(Palette.inkOn)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.ink, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                // Over images and colours: black 55% pill, so white text stays above 4.5:1 even on a white image.
                Text(detail).font(.subheadline).foregroundStyle(fullBleed ? Color.white : Color.secondary).lineLimit(1)
                    .padding(.horizontal, fullBleed ? 8 : 0).padding(.vertical, fullBleed ? 2 : 0)
                    .background { if fullBleed { Capsule().fill(.black.opacity(increased ? 0.7 : 0.55)) } }
            }
            Spacer(minLength: 0)
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
        } else if item.kind == .file, let thumb {
            Checkerboard().overlay { Image(nsImage: thumb).resizable().scaledToFit().padding(10) }.clipped()
        } else if item.kind == .file {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary)
                Text(item.fileNames.joined(separator: "\n")).font(.callout).lineLimit(5)
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if item.kind == .link {
            VStack(alignment: .leading, spacing: 4) {
                if let d = item.extras?["linkImage"], let img = NSImage(data: d) {
                    Image(nsImage: img).resizable().scaledToFill().frame(height: 96).frame(maxWidth: .infinity).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let t = item.extras?["linkTitle"].flatMap({ String(data: $0, encoding: .utf8) }) {
                    Text(t).font(.callout.weight(.semibold)).foregroundStyle(Palette.brandInk).lineLimit(item.extras?["linkImage"] == nil ? 3 : 2)
                    Text(item.text ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(item.extras?["linkImage"] == nil ? 2 : 1)
                } else {
                    Image(systemName: "link").foregroundStyle(Palette.accent)
                    Text(item.text ?? item.title).font(.callout).lineLimit(5)
                }
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let styled = RichText.attributed(item) {
            Text(styled).lineSpacing(1)
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.62), .init(color: .clear, location: 0.86)], startPoint: .top, endPoint: .bottom))
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
        let L = Contrast.luminance(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
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
