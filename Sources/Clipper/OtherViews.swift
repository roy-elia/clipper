import SwiftUI
import DropCore

struct PreviewView: View {
    let item: ClipItem
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.kind.rawValue.capitalized).font(.headline)
                Spacer()
                if let b = item.sourceBundleID { Text(b).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            Group {
                if item.kind == .image, let d = item.data, let img = NSImage(data: d) {
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
        .accessibilityIdentifier("preview.root")
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
                            Text(it.title).lineLimit(1)
                            Spacer()
                            Button { model.stack.remove(it.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                                .accessibilityLabel("Remove \(it.title)")
                        }
                    }
                }.listStyle(.plain)
            }
        }
        .padding(16).frame(width: 360, height: 300)
    }
}

struct SettingsView: View {
    @ObservedObject var model: ShelfModel
    var accessibilityTrusted: Bool
    var mcpToken: String = ""
    var onGrant: () -> Void = {}
    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Open shelf") { Text(model.settings.hotkey.display).font(.body.monospaced()) }
                Toggle("Play sounds", isOn: Binding(get: { model.settings.playSounds }, set: { v in model.updateSettings { $0.playSounds = v } }))
                    .accessibilityIdentifier("settings.sounds")
            }
            Section("History") {
                LabeledContent("Keep up to") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.settings.historyCapacity) },
                                              set: { v in model.updateSettings { $0.setCapacity(Int(v)) } }),
                               in: Double(AppSettings.capacityRange.lowerBound)...Double(AppSettings.capacityRange.upperBound), step: 50)
                            .frame(width: 180).accessibilityIdentifier("settings.capacity")
                        Text("\(model.settings.historyCapacity)").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Text("Clips on a pinboard are never removed.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Clips from password managers and anything marked concealed are never saved.").font(.callout)
                LabeledContent("Ignored apps") { Text("\(model.settings.ignoredBundleIDs.count) password managers").foregroundStyle(.secondary) }
            }
            Section("MCP server") {
                Toggle("Let AI tools use my clips", isOn: Binding(get: { model.settings.mcpEnabled }, set: { v in model.updateSettings { $0.mcpEnabled = v } }))
                    .accessibilityIdentifier("settings.mcp")
                LabeledContent("Address") { Text("http://127.0.0.1:\(String(model.settings.mcpPort))/mcp").font(.caption.monospaced()).textSelection(.enabled) }
                LabeledContent("Token") {
                    HStack {
                        Text(String(repeating: "•", count: 12)).foregroundStyle(.secondary)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(mcpToken, forType: .string) }
                            .disabled(mcpToken.isEmpty).accessibilityIdentifier("settings.copyToken")
                    }
                }
                Text("Only this Mac can connect, and every request needs the token. Use clipper-mcp-stdio for clients that speak stdio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Accessibility (paste)") {
                    if accessibilityTrusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button("Allow…", action: onGrant).accessibilityIdentifier("settings.grant") }
                }
            }
        }
        .formStyle(.grouped).frame(width: 460, height: 520)
    }
}
