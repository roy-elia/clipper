import SwiftUI
import DropCore

struct PreviewView: View {
    let item: ClipItem
    var onSave: (String) -> Void = { _ in }
    var startEditing = false
    @FocusState private var editorFocused: Bool
    @State private var revealed = false
    @State private var editing = false
    @State private var draft = ""
    init(item: ClipItem, onSave: @escaping (String) -> Void = { _ in }, startEditing: Bool = false) {
        self.item = item; self.onSave = onSave; self.startEditing = startEditing
        let editable = item.kind == .text && item.data == nil && !item.isSecret
        _editing = State(initialValue: startEditing && editable)
        _draft = State(initialValue: startEditing && editable ? (item.text ?? "") : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.customTitle ?? item.kind.rawValue.capitalized).font(.headline)
                Spacer()
                if item.kind == .text, item.data == nil, !item.isSecret || revealed {
                    if editing {
                        Button("Cancel") { editing = false }
                        Button("Save") { onSave(draft); editing = false }.keyboardShortcut(.defaultAction).accessibilityIdentifier("preview.save")
                    } else {
                        Button("Edit") { draft = item.text ?? ""; editing = true }.accessibilityIdentifier("preview.edit")
                    }
                }
                if let b = item.sourceBundleID { Text(b).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            Group {
                if item.isSecret && !revealed {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                        Text("This clip looks like a secret and is hidden.").foregroundStyle(.secondary)
                        Button("Reveal") { revealed = true }.accessibilityIdentifier("preview.reveal")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if editing {
                    TextEditor(text: $draft).font(.body.monospaced()).scrollContentBackground(.hidden).padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("preview.editor")
                        .focused($editorFocused).onAppear { editorFocused = true }
                } else if item.kind == .image, let d = item.data, let img = NSImage(data: d) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    ScrollView { Text(item.text ?? item.title).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.frame(maxHeight: .infinity)
            HStack {
                Text(item.kind == .image ? "\(item.data?.count ?? 0) bytes" : "\((item.text ?? "").count) characters").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(width: 440, height: 320)
        .clipperStyle().accessibilityIdentifier("preview.root")
    }
}

struct StackView: View {
    @ObservedObject var model: ShelfModel
    var onPasteNext: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Paste Stack").font(.headline)
                Spacer()
                Button("Clear") { model.stack.clear() }.disabled(model.stack.isEmpty).accessibilityIdentifier("stack.clear")
                Button("Paste Next", action: onPasteNext).keyboardShortcut(.return)
                    .disabled(model.stack.isEmpty).accessibilityIdentifier("stack.pasteNext")
            }
            if model.stack.isEmpty {
                Text("Right-click a clip and choose Add to Paste Stack. Each paste sends the next one in order.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.stack.items.enumerated()), id: \.element.id) { i, it in
                        HStack {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                            Text(it.isSecret ? "Secret (hidden)" : it.title).lineLimit(1)
                            Spacer()
                            Button { model.stack.remove(it.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                                .accessibilityLabel("Remove \(it.isSecret ? "secret clip" : it.title)")
                        }
                    }
                }.listStyle(.plain)
            }
        }
        .padding(16).frame(width: 360, height: 300).clipperStyle()
    }
}

/// The sections of the Settings window's sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, picks, privacy, shortcuts, aiTools
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "General"; case .picks: "Picks"; case .privacy: "Privacy"; case .shortcuts: "Shortcuts"; case .aiTools: "AI Tools" }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .picks: "sparkles"; case .privacy: "hand.raised"; case .shortcuts: "keyboard"; case .aiTools: "point.3.connected.trianglepath.dotted" }
    }
}

/// Settings: a sidebar of sections, each a grouped form.
struct SettingsView: View {
    @ObservedObject var model: ShelfModel
    var accessibilityTrusted: Bool
    var mcpToken: String = ""
    var clients: ClientsModel? = nil
    var modelNote: String = ""
    var syncAvailable = CloudKitTransport.available
    @State var pane: SettingsPane = .general
    @State private var loginEnabled = LoginItem.enabled
    var onGrant: () -> Void = {}

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) { p in
                Label(p.title, systemImage: p.symbol).tag(p).accessibilityIdentifier("settings.pane.\(p.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form { content }
                .formStyle(.grouped)
                .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 560)
        .clipperStyle()
    }

    @ViewBuilder var content: some View {
        switch pane {
        case .general: general
        case .picks: picks
        case .privacy: privacy
        case .shortcuts: shortcuts
        case .aiTools: aiTools
        }
    }

    func setting<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] }, set: { v in model.updateSettings { $0[keyPath: key] = v } })
    }

    // MARK: General

    @ViewBuilder var general: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { loginEnabled }, set: { v in LoginItem.set(v); loginEnabled = LoginItem.enabled }))
                .accessibilityIdentifier("settings.login")
            Toggle(isOn: setting(\.showMenuBarIcon)) {
                Text("Show in menu bar")
                Text("With the icon hidden, open Clipper from Spotlight or Finder, or use the shortcut.")
            }.accessibilityIdentifier("settings.menuBar")
            Toggle(isOn: setting(\.iCloudSync)) {
                HStack {
                    Text("Sync clips with iCloud")
                    Spacer()
                    if model.settings.iCloudSync {
                        Text(SyncButton.status(syncing: model.syncing, last: model.lastSynced)).foregroundStyle(.secondary).accessibilityIdentifier("settings.syncStatus")
                    }
                }
                Text(syncAvailable ? "Secrets and clips over 5 MB stay on this Mac." : "Needs a build signed with an iCloud container. This build can't sync.")
            }.disabled(!syncAvailable).accessibilityIdentifier("settings.sync")
            Toggle("Play sounds", isOn: setting(\.playSounds)).accessibilityIdentifier("settings.sounds")
            Toggle("Index clips in Spotlight", isOn: setting(\.spotlightEnabled)).accessibilityIdentifier("settings.spotlight")
        }
        Section("Picking a Clip") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    targetRow(.activeApp, "Paste into the front app", "The clip goes straight into the app you were using.")
                    targetRow(.clipboard, "Copy to the clipboard", "The clip waits on the clipboard; press ⌘V where you want it.")
                }
                Spacer(minLength: 0)
                TargetIllustration(target: model.settings.pasteTarget)
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("settings.pasteTarget")
            Toggle("Always paste as plain text", isOn: setting(\.alwaysPlain)).accessibilityIdentifier("settings.alwaysPlain")
            Toggle(isOn: setting(\.linkPreviews)) {
                Text("Fetch page titles for copied links")
                Text("Sends a request to the link's site when you copy it. Off by default.")
            }.accessibilityIdentifier("settings.linkPreviews")
        }
        Section("Keep History") {
            VStack(spacing: 4) {
                Slider(value: Binding(get: { Double(Retention.allCases.firstIndex(of: model.settings.retention) ?? 0) },
                                      set: { v in model.updateSettings { $0.retention = Retention.allCases[Int(v.rounded())] } }),
                       in: 0...Double(Retention.allCases.count - 1), step: 1)
                    .accessibilityIdentifier("settings.retention")
                    .accessibilityValue(model.settings.retention.label)
                HStack {
                    ForEach(Retention.allCases, id: \.self) { r in
                        Text(r.rawValue.capitalized).font(.callout).frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, -12).accessibilityHidden(true)
            }
            LabeledContent("Keep up to") {
                HStack {
                    Slider(value: Binding(get: { Double(model.settings.historyCapacity) },
                                          set: { v in model.updateSettings { $0.setCapacity(Int(v)) } }),
                           in: Double(AppSettings.capacityRange.lowerBound)...Double(AppSettings.capacityRange.upperBound), step: 50)
                        .frame(width: 180).accessibilityIdentifier("settings.capacity")
                    Text("\(model.settings.historyCapacity) clips").monospacedDigit().frame(width: 76, alignment: .trailing)
                }
            }
            HStack {
                Text("Clips on a pinboard are never removed.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { model.onClear?() }.accessibilityIdentifier("settings.clearHistory")
            }
        }
    }

    func targetRow(_ t: PasteTarget, _ title: String, _ detail: String) -> some View {
        let on = model.settings.pasteTarget == t
        return Button { model.updateSettings { $0.pasteTarget = t } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: on ? "circle.inset.filled" : "circle").foregroundStyle(on ? Palette.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : []).accessibilityIdentifier("settings.pasteTarget.\(t.rawValue)")
    }

    // MARK: Picks

    @ViewBuilder var picks: some View {
        Section {
            Toggle("Open on Picks", isOn: setting(\.opensOnPicks)).accessibilityIdentifier("settings.picks")
            Picker("Show Picks", selection: setting(\.suggestTrigger)) {
                Text("Every time the shelf opens").tag(SuggestTrigger.always)
                Text("When you open it from a different app").tag(SuggestTrigger.appChanged)
            }.disabled(!model.settings.opensOnPicks).accessibilityIdentifier("settings.suggestTrigger")
        }
        Section {
            Toggle(isOn: setting(\.smartModel)) {
                Text("Ask the on-device model about unclear clips")
                if !SmartClassifier.isAvailable { Text("Requires Apple Intelligence. Picks still work from your paste history.").accessibilityIdentifier("settings.requiresAI") }
            }.accessibilityIdentifier("settings.smartModel")
        }
    }

    // MARK: Privacy

    @ViewBuilder var privacy: some View {
        Section {
            Toggle("Hide Clipper from screen sharing and recordings", isOn: setting(\.hideFromSharing)).accessibilityIdentifier("settings.hideSharing")
            Toggle("Skip passwords other apps mark as confidential", isOn: setting(\.ignoreConfidential)).accessibilityIdentifier("settings.ignoreConfidential")
            Toggle("Skip temporary content other apps mark as transient", isOn: setting(\.ignoreTransient)).accessibilityIdentifier("settings.ignoreTransient")
        }
        Section {
            Picker("Clips that look like secrets", selection: setting(\.secretPolicy)) {
                Text("Hide").tag(SecretPolicy.mask)
                Text("Hide, then delete").tag(SecretPolicy.expire)
                Text("Never save").tag(SecretPolicy.skip)
            }.accessibilityIdentifier("settings.secretPolicy")
            if model.settings.secretPolicy == .expire {
                Stepper("Delete after \(model.settings.secretMinutes) min", value: setting(\.secretMinutes), in: 1...120)
            }
        } header: { Text("Secrets") } footer: {
            Text("Secrets are never suggested, never shown to AI tools and never indexed. Detection runs on this Mac.\(modelNote)")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section("Ignored Apps") {
            Text("Clips from these apps are never saved.").font(.callout).foregroundStyle(.secondary)
            IgnoredAppsEditor(ids: setting(\.ignoredBundleIDs))
        }
        Section("Permissions") {
            LabeledContent {
                if accessibilityTrusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Button("Allow…", action: onGrant).accessibilityIdentifier("settings.grant") }
            } label: {
                Text("Accessibility")
                Text("Needed to paste into other apps.")
            }
        }
    }

    // MARK: Shortcuts

    @ViewBuilder var shortcuts: some View {
        Section {
            LabeledContent("Open the shelf") {
                HotkeyRecorder(current: model.settings.hotkey) { hk in model.updateSettings { $0.hotkey = hk } }.id(model.settings.hotkey)
            }
            LabeledContent("Paste next in Paste Stack") {
                HotkeyRecorder(current: model.settings.stackHotkey) { hk in model.updateSettings { $0.stackHotkey = hk } }.id(model.settings.stackHotkey)
            }
            Picker(selection: setting(\.quickModifier)) {
                ForEach(QuickModifier.allCases, id: \.self) { Text("\($0.symbol) + 1…9").tag($0) }
            } label: {
                Text("Quick paste")
                Text("Hold it and press 1 to 9 while the shelf is open.")
            }.accessibilityIdentifier("settings.quickModifier")
        }
        Section {
            HStack { Spacer(); Button("Reset Shortcuts to Default") { model.updateSettings { $0.resetShortcuts() } }.accessibilityIdentifier("settings.resetShortcuts") }
        }
    }

    // MARK: AI Tools

    @ViewBuilder var aiTools: some View {
        Section {
            Toggle(isOn: setting(\.mcpEnabled)) {
                Text("Let AI tools use my clips")
                Text("Connected tools can search and read clips on this Mac. Secrets are never shared.")
            }.accessibilityIdentifier("settings.mcp")
            LabeledContent("Address") { Text("http://127.0.0.1:\(String(model.settings.mcpPort))/mcp").font(.callout.monospaced()).textSelection(.enabled) }
        }
        if let clients { Section("Connected") { AIToolsSection(clients: clients, model: model) } }
    }
}

/// A small drawing beside the "Picking a clip" choice: a card dropping into a window, or onto the clipboard.
struct TargetIllustration: View {
    let target: PasteTarget
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.58, blue: 1), Color(red: 0.17, green: 0.38, blue: 0.92)], startPoint: .top, endPoint: .bottom))
            Image(systemName: target == .activeApp ? "macwindow.badge.plus" : "doc.on.clipboard")
                .font(.system(size: 40, weight: .regular)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 150, height: 100)
        .accessibilityHidden(true)
    }
}

/// Bundle ids of apps whose clipboard is never saved. Add the frontmost running app or type an id.
struct IgnoredAppsEditor: View {
    @Binding var ids: [String]
    @State private var newID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ids, id: \.self) { id in
                HStack {
                    Text(AppInfo.name(id)).lineLimit(1)
                    Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { ids.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        .accessibilityLabel("Stop ignoring \(id)")
                }
            }
            HStack {
                TextField("Bundle ID", text: $newID, prompt: Text("com.example.app")).labelsHidden().textFieldStyle(.roundedBorder).accessibilityIdentifier("settings.ignoreField")
                Button("Add") {
                    let t = newID.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty, !ids.contains(t) { ids.append(t) }; newID = ""
                }.disabled(newID.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("settings.ignoreAdd")
            }
        }
    }
}
