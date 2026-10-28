import AppKit
import AVFoundation
import SwiftUI
import DropCore

/// Short sounds synthesized here, so no audio file is bundled or copied from anywhere. Copy is a soft paper "snip"
/// (two quick ticks of filtered noise and a faint rustle); paste is a short wooden "tock". Both stay quiet and
/// under a fifth of a second, so they confirm an action without calling attention to it.
@MainActor
final class SoundFeedback {
    enum Cue { case copy, paste }
    private var players: [Cue: AVAudioPlayer] = [:]
    var enabled = false

    nonisolated static let rate = 44_100.0

    /// Copy: two ticks 18 ms apart (the second brighter), then an airy rustle that fades out by about 190 ms.
    static func copySamples() -> [Double] {
        let n = Int(0.19 * rate)
        var out = [Double](repeating: 0, count: n)
        var noise = Noise(seed: 0xC11)
        let tick1 = Bandpass(centre: 3_100, q: 1.6), tick2 = Bandpass(centre: 7_400, q: 1.4), air = Bandpass(centre: 9_800, q: 0.8)
        for i in 0..<n {
            let t = Double(i) / rate, w = noise.next()
            var v = 0.0
            if t < 0.012 { v += tick1.run(w) * 0.55 * exp(-t / 0.0022) }
            if t >= 0.018 { let u = t - 0.018; v += tick2.run(w) * 0.9 * exp(-u / 0.0028) }
            // The rustle swells after the ticks and fades with a raised-cosine tail.
            if t >= 0.06 { let u = (t - 0.06) / 0.13; v += air.run(w) * 0.09 * sin(.pi * min(1, u)) }
            out[i] = v
        }
        return normalised(out, peak: 0.16)
    }

    /// Paste: a damped sine near 1 kHz that drops slightly in pitch, with a 1 ms attack; gone in about 25 ms.
    static func pasteSamples() -> [Double] {
        let n = Int(0.08 * rate)
        var out = [Double](repeating: 0, count: n), phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            let f = 980 + 90 * exp(-t / 0.006)
            phase += 2 * .pi * f / rate
            let env = min(1, t / 0.001) * exp(-t / 0.0055)
            out[i] = (sin(phase) + 0.18 * sin(2.01 * phase)) * env
        }
        return normalised(out, peak: 0.32)
    }

    static func samples(for cue: Cue) -> [Double] { cue == .copy ? copySamples() : pasteSamples() }

    static func normalised(_ x: [Double], peak: Double) -> [Double] {
        let m = x.map(abs).max() ?? 1
        return m > 0 ? x.map { $0 / m * peak } : x
    }

    /// Mono 16-bit PCM WAV.
    static func wav(for cue: Cue) -> Data { wav(samples(for: cue)) }
    static func wav(_ samples: [Double]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * Double(Int16.max)))) }
        return d
    }

    /// Repeatable white noise, so the sound is identical every launch.
    struct Noise {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: state)) / Double(Int64.max)
        }
    }

    /// RBJ band-pass biquad (constant peak gain), used to colour the noise.
    final class Bandpass {
        let b0, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        init(centre: Double, q: Double) {
            let w = 2 * .pi * centre / SoundFeedback.rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
            b0 = alpha / a0; b2 = -alpha / a0; a1 = -2 * cos(w) / a0; a2 = (1 - alpha) / a0
        }
        func run(_ x: Double) -> Double {
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    private func player(_ cue: Cue) -> AVAudioPlayer? {
        if let p = players[cue] { return p }
        let data = Self.wav(for: cue)
        guard let p = try? AVAudioPlayer(data: data) else { return nil }
        p.volume = 1; p.prepareToPlay(); players[cue] = p
        return p
    }

    @discardableResult
    func play(_ cue: Cue) -> Bool {
        guard enabled else { return false }
        guard let p = player(cue) else { PasteInjector.diag("sound: \(cue) no player"); return false }
        p.currentTime = 0
        let ok = p.play()
        PasteInjector.diag("sound: \(cue) played=\(ok)")
        return ok
    }
}

/// A brief floating message ("Pasted 2 of 5", "Capture paused"). Never takes focus.
@MainActor
/// The notice's backdrop: Liquid Glass in a capsule, with a material before macOS 26.
struct GlassCapsule: View {
    var body: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
}

final class OSD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String? = nil, hideFromSharing: Bool = true) {
        lastText = text
        let view = HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.system(size: 15)) }
            Text(text).font(.body.weight(.medium))
        }
        .foregroundStyle(Palette.glassLabel)
        .padding(.horizontal, 16).padding(.vertical, 10).background { GlassCapsule() }
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
                    Label { Text("Welcome to Clipper") } icon: { Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32) }.font(.title2.weight(.semibold))
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
        .padding(24).frame(width: 440, height: 260).clipperStyle()
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
        }.padding(24).frame(width: 440, height: 280).clipperStyle()
    }
}

struct AboutView: View {
    let version: String
    let build: String
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Clipper").font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))").font(.callout).foregroundStyle(.secondary)
            Text("A personal clipboard manager.").font(.callout)
        }.padding(24).frame(width: 300, height: 190)
    }
}


/// Help ▸ Keyboard Shortcuts.
struct ShortcutsView: View {
    let settings: AppSettings
    var rows: [(String, String)] {
        let q = settings.quickModifier.symbol
        return [("Open the shelf", settings.hotkey.display), ("Paste from the Paste Stack", settings.stackHotkey.display),
                ("Paste the selected clip", "↩"), ("Paste as plain text", "⇧↩ or ⇧-click"), ("Paste clip 1…9", "\(q)1…\(q)9"),
                ("Move between clips", "← →"), ("Next / previous pinboard", "⌘→ / ⌘←"), ("Preview", "Space"),
                ("Copy without pasting", "⌘C"), ("Edit", "⌘E"), ("Rename", "⌘R"), ("Delete", "⌫ (⌘Z to undo)"), ("Close", "Esc")]
    }
    var body: some View {
        Form {
            ForEach(rows, id: \.0) { r in LabeledContent(r.0) { Text(r.1).font(.body.monospaced()).foregroundStyle(.secondary) } }
        }.formStyle(.grouped).frame(width: 380)
    }
}
