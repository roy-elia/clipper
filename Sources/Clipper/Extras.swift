import AppKit
import AVFoundation
import SwiftUI
import DropCore

/// Short sounds synthesized here (a soft two-note chime each), so no audio file is bundled or copied from anywhere.
@MainActor
final class SoundFeedback {
    enum Cue { case copy, paste }
    private var players: [Cue: AVAudioPlayer] = [:]
    var enabled = false

    static func wav(freqs: [Double], noteSeconds: Double = 0.07, rate: Double = 44_100) -> Data {
        var samples: [Int16] = []
        for f in freqs {
            let n = Int(noteSeconds * rate)
            for i in 0..<n {
                let t = Double(i) / rate, env = min(1, Double(i) / 200) * pow(1 - Double(i) / Double(n), 1.6)
                samples.append(Int16(max(-1, min(1, sin(2 * .pi * f * t) * env * 0.35)) * Double(Int16.max)))
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }

    private func player(_ cue: Cue) -> AVAudioPlayer? {
        if let p = players[cue] { return p }
        let data = Self.wav(freqs: cue == .copy ? [660, 880] : [880, 660])
        guard let p = try? AVAudioPlayer(data: data) else { return nil }
        p.volume = 0.5; p.prepareToPlay(); players[cue] = p
        return p
    }

    @discardableResult
    func play(_ cue: Cue) -> Bool {
        guard enabled, let p = player(cue) else { return false }
        p.currentTime = 0; return p.play()
    }
}

/// A brief floating message ("Pasted 2 of 5", "Capture paused"). Never takes focus.
@MainActor
final class OSD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String? = nil, hideFromSharing: Bool = true) {
        lastText = text
        let view = HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol) }
            Text(text).font(.callout.weight(.medium))
        }.padding(.horizontal, 16).padding(.vertical, 10).background { ShelfBackdrop() }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
            p.ignoresMouseEvents = true; p.level = .statusBar
            panel = p
        }
        panel?.sharingType = hideFromSharing ? .none : .readOnly
        panel?.contentView = host
        panel?.setContentSize(size)
        if let s = NSScreen.main { panel?.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - size.width / 2, y: s.visibleFrame.maxY - size.height - 60)) }
        panel?.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    var isShowing: Bool { panel?.isVisible == true }
    private(set) var lastText: String?
}

struct OnboardingView: View {
    @State private var step = 0
    @State private var trusted = PasteInjector.trusted
    let hotkey: Hotkey
    var onGrant: () -> Void
    var onFinish: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                switch step {
                case 0:
                    Label("Welcome to Clipper", systemImage: "paperclip").font(.title2.weight(.semibold))
                    Text("Clipper remembers what you copy so you can paste it again. Everything stays on this Mac.")
                case 1:
                    Label("Let Clipper paste for you", systemImage: "hand.tap").font(.title2.weight(.semibold))
                    Text("To paste into the app you are using, Clipper needs the Accessibility permission. Without it, picking a clip only copies it.")
                    HStack {
                        if trusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        else { Button("Allow…", action: onGrant).accessibilityIdentifier("onboarding.grant") }
                    }
                default:
                    Label("You're set", systemImage: "checkmark.seal").font(.title2.weight(.semibold))
                    Text("Press \(hotkey.display) anywhere to open your clips. Use the arrow keys and Return to paste, ⇧Return for plain text, and ⌘1–9 for the first nine.")
                }
            }
            Spacer()
            HStack {
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Start" : "Continue") { if step == 2 { onFinish() } else { step += 1 } }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("onboarding.next")
            }
        }
        .padding(24).frame(width: 440, height: 260)
        .onReceive(timer) { _ in trusted = PasteInjector.trusted }
    }
}

struct WhatsNewView: View {
    let version: String
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's new in Clipper \(version)").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Label("Picks suggests the right clip for the app you're in", systemImage: "sparkles")
                Label("Secrets are detected, hidden, and never shared", systemImage: "lock.fill")
                Label("Keyboard control: arrows, Return, ⇧Return, ⌘1–9", systemImage: "keyboard")
                Label("Paste Stack with collect mode and its own shortcut", systemImage: "square.stack.3d.up")
                Label("MCP server so AI tools can use your clips", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Spacer()
            HStack { Spacer(); Button("OK", action: onClose).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 440, height: 280)
    }
}

struct AboutView: View {
    let version: String
    let build: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "paperclip").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Clipper").font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))").font(.callout).foregroundStyle(.secondary)
            Text("A personal clipboard manager.").font(.callout)
        }.padding(24).frame(width: 300, height: 190)
    }
}
