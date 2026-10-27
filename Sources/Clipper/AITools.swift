import AppKit
import SwiftUI
import DropCore

/// Settings ▸ AI tools: each connected tool has its own token, so it can be listed and disconnected alone.
@MainActor
final class ClientsModel: ObservableObject {
    let clients: MCPClients
    @Published var list: [MCPClient] = []
    var onPortChange: ((UInt16) -> Void)?
    init(_ c: MCPClients) { clients = c; reload() }
    func reload() { list = clients.all.sorted { $0.created < $1.created } }
    func add(_ name: String) -> MCPClient { let c = clients.add(name); reload(); return c }
    func remove(_ c: MCPClient) { clients.remove(c.id); reload() }

    /// The stdio bridge shipped inside the app bundle.
    static var bridgePath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clipper-mcp-stdio").path }
}

struct AIToolsSection: View {
    @ObservedObject var clients: ClientsModel
    @ObservedObject var model: ShelfModel
    @State private var connecting = false
    @State private var portText = ""

    var body: some View {
        if clients.list.isEmpty {
            Text("Nothing connected yet").foregroundStyle(.secondary).accessibilityIdentifier("ai.empty")
        }
        ForEach(clients.list) { c in
            LabeledContent {
                Button("Disconnect…") { confirmDisconnect(c) }.accessibilityIdentifier("ai.disconnect.\(c.name)")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name)
                    Text(c.lastUsed.map { "Last used " + Relative.string(from: $0) } ?? "Never used").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        HStack {
            Spacer()
            Button("Connect AI Tool…") { connecting = true }.accessibilityIdentifier("ai.connect")
        }
        .sheet(isPresented: $connecting) { ConnectToolSheet(clients: clients, port: model.settings.mcpPort) { connecting = false } }
        LabeledContent("Server port") {
            HStack {
                TextField("", text: $portText).frame(width: 70).textFieldStyle(.roundedBorder).accessibilityIdentifier("ai.port")
                Button("Change") { changePort() }.accessibilityIdentifier("ai.portChange").disabled(UInt16(portText) == nil || UInt16(portText) == model.settings.mcpPort)
            }
        }
        .onAppear { portText = String(model.settings.mcpPort) }
        Text("Only this Mac can connect, and each tool needs its own token. Changing the port means each tool's settings must be updated.")
            .font(.caption).foregroundStyle(.secondary)
    }

    func confirmDisconnect(_ c: MCPClient) {
        let a = NSAlert(); a.messageText = "Disconnect “\(c.name)”?"
        a.informativeText = "It will no longer be able to read your clips. Connect it again to get a new token."
        a.addButton(withTitle: "Disconnect"); a.addButton(withTitle: "Cancel")
        if runAlert(a) == .alertFirstButtonReturn { clients.remove(c) }
    }

    func changePort() {
        guard let p = UInt16(portText), p >= 1024 else { portText = String(model.settings.mcpPort); return }
        let a = NSAlert(); a.messageText = "Change the server port to \(p)?"
        a.informativeText = "Connected tools keep their tokens but must be pointed at the new address."
        a.addButton(withTitle: "Change"); a.addButton(withTitle: "Cancel")
        if runAlert(a) == .alertFirstButtonReturn { model.updateSettings { $0.mcpPort = p } } else { portText = String(model.settings.mcpPort) }
    }
}

/// Name the tool, then copy the configuration it needs (a JSON block, or one command for Claude Code).
struct ConnectToolSheet: View {
    @ObservedObject var clients: ClientsModel
    let port: UInt16
    var onDone: () -> Void
    @State private var name = ""
    @State private var created: MCPClient?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect an AI Tool").font(.headline)
            if let c = created {
                Text("Add the following to \(c.name)'s MCP configuration:").font(.callout)
                snippet(MCPClients.config(name: c.name, bridgePath: ClientsModel.bridgePath, token: c.token, port: port), id: "ai.config")
                Text("For Claude Code, run this in Terminal, then type /mcp to check it:").font(.callout)
                snippet(claudeCommand(c), id: "ai.claudeCommand")
                HStack { Spacer(); Button("Done") { onDone() }.keyboardShortcut(.defaultAction) }
            } else {
                TextField("Name (e.g. Claude Code)", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("ai.name")
                HStack {
                    Spacer()
                    Button("Cancel") { onDone() }
                    Button("Connect") { created = clients.add(name) }.keyboardShortcut(.defaultAction).accessibilityIdentifier("ai.create")
                }
            }
        }
        .padding(18).frame(width: 520)
    }

    func claudeCommand(_ c: MCPClient) -> String {
        "claude mcp add clipper-\(c.name.lowercased().replacingOccurrences(of: " ", with: "-")) -e MCP_URL=http://127.0.0.1:\(port)/mcp -e MCP_TOKEN=\(c.token) -- \"\(ClientsModel.bridgePath)\""
    }

    func snippet(_ s: String, id: String) -> some View {
        HStack(alignment: .top) {
            Text(s).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") { copyWithoutSaving(s) }
                .accessibilityIdentifier(id + ".copy")
        }
        .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }
}

/// Puts text on the clipboard marked transient, so Clipper (and other clipboard managers) don't save it.
/// Used for tokens and configuration that contain them.
func copyWithoutSaving(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
    pb.setString(s, forType: .string)
    pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
}

/// Brings Clipper to the front for a window that needs the keyboard. The polite activate() can be refused by
/// macOS when another app is active, which would send typing to that app instead.
@MainActor func bringClipperForward() {
    NSApp.activate(ignoringOtherApps: true)
}

/// Runs an alert that takes the keyboard even while another app is active, for the same reason as KeyWindow:
/// Clipper often can't become the active app, and an ordinary alert would leave typing going to that app. The
/// alert's own layout is moved into a KeyWindow, since that ability can only be given to a window when it's made.
@MainActor func runAlert(_ a: NSAlert) -> NSApplication.ModalResponse {
    let wanted = a.window.initialFirstResponder
    a.layout()
    let src = a.window
    let w = KeyWindow(contentRect: src.contentRect(forFrameRect: src.frame), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    w.title = ""; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true
    w.isMovableByWindowBackground = true; w.level = .modalPanel
    let content = src.contentView; src.contentView = NSView(); w.contentView = content
    for case let b as NSButton in a.buttons {
        b.target = AlertStopper.shared; b.action = #selector(AlertStopper.stop(_:))
    }
    w.center(); w.makeKeyAndOrderFront(nil)
    if let f = wanted { w.makeFirstResponder(f) }
    let r = NSApp.runModal(for: w)
    w.orderOut(nil)
    return r
}

/// Ends the modal session with the pressed button's position (first, second, third), like NSAlert does.
@MainActor final class AlertStopper: NSObject {
    static let shared = AlertStopper()
    @objc func stop(_ b: NSButton) { NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: b.tag)) }
}
