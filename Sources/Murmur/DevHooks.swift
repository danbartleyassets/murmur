import SwiftUI
import AppKit
import MurmurCore

/// Development hooks, driven by environment variables when launching the binary
/// directly. Not reachable from the normal app.
///
///   MURMUR_SELFTEST=<audio file> [MURMUR_SELFTEST_OUT=<txt>] [MURMUR_SELFTEST_VOCAB=a,b]
///       Loads the model, transcribes the file, writes the text, quits.
///   MURMUR_RENDER=<dir>
///       Renders the window pages (light and dark) and HUD states to PNGs, quits.
@MainActor
enum DevHooks {
    static let isRendering = ProcessInfo.processInfo.environment["MURMUR_RENDER"] != nil

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let file = env["MURMUR_SELFTEST"] {
            selfTest(file: file, out: env["MURMUR_SELFTEST_OUT"],
                     vocabulary: env["MURMUR_SELFTEST_VOCAB"]?.split(separator: ",").map(String.init) ?? [])
            return true
        }
        if env["MURMUR_MICTEST"] != nil {
            let recorder = AudioRecorder()
            print("default input:", AudioDevices.defaultInput()?.name ?? "none", "| inputs:", AudioDevices.inputs().map(\.name))
            let ok = recorder.start(deviceUID: "")
            print("recorder.start ->", ok)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let r = recorder.stop()
                print("stop -> samples \(r.samples.count), peak \(r.peak)")
                exit(0)
            }
            return true
        }
        if let dir = env["MURMUR_RENDER"] {
            render(to: URL(fileURLWithPath: dir))
            return true
        }
        return false
    }

    // MARK: Self-test

    private static func selfTest(file: String, out: String?, vocabulary: [String]) {
        let transcriber = Transcriber()
        let model = SettingsStore.shared.modelName
        Task {
            let started = Date()
            await transcriber.load(model: model) { status in
                print("model: \(status)")
            }
            let loadSeconds = Date().timeIntervalSince(started)
            let t0 = Date()
            let raw = await transcriber.transcribe(file: file, language: "en")
            let text = SoundsLike.correct(raw, terms: vocabulary)
            let report = """
            load_seconds: \(String(format: "%.1f", loadSeconds))
            transcribe_seconds: \(String(format: "%.2f", Date().timeIntervalSince(t0)))
            text: \(text)
            """
            print(report)
            if let out { try? report.write(toFile: out, atomically: true, encoding: .utf8) }
            exit(text.isEmpty ? 1 : 0)
        }
    }

    // MARK: Renders

    private static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = AppState.shared
        state.setPreviewState(model: .downloading(0.42), mic: true, accessibility: false)
        History.shared.previewFill([
            "Hi Jack, the container should land at Mulgrave on the ninth. I'll confirm once GDF send the arrival notice.",
            "Can we move the Kasaro call to Thursday morning?",
            "Remember to send Christian the recap from Wednesday's meeting.",
        ])
        VocabularyStore.shared.previewFill(terms: ["Acupanel", "Kasaro", "WVH", "Mulgrave"],
                                           corrections: ["acu panel": "Acupanel", "car sorrow": "Kasaro"])

        Task {
            let wm = RenderWindowHost()
            try? await Task.sleep(for: .seconds(1.0))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                wm.window?.appearance = NSAppearance(named: appearance)
                let suffix = appearance == .aqua ? "light" : "dark"
                for (page, setup) in [(Page.home, "setup"), (.home, "ready"), (.general, ""), (.dictation, ""), (.vocabulary, ""), (.ask, "")] {
                    if page == .home {
                        if setup == "setup" { state.setPreviewState(model: .downloading(0.42), mic: true, accessibility: false) }
                        else { state.setPreviewState(model: .ready, mic: true, accessibility: true) }
                    }
                    wm.nav.page = page
                    try? await Task.sleep(for: .seconds(0.6))
                    let name = setup.isEmpty ? page.rawValue : "\(page.rawValue)-\(setup)"
                    snapshot(wm.window, to: dir.appendingPathComponent("window-\(name)-\(suffix).png"))
                }
            }

            // HUD states over a stand-in desktop.
            let started = Date().addingTimeInterval(-7)
            let states: [(String, HUDContent)] = [
                ("recording", .recording(mode: .dictate, locked: false, started: started)),
                ("locked", .recording(mode: .dictate, locked: true, started: started.addingTimeInterval(-64))),
                ("ask", .recording(mode: .ask, locked: false, started: started)),
                ("working", .working(mode: .dictate)),
                ("done", .done(copied: false)),
                ("copied", .done(copied: true)),
                ("notice", .message(symbol: "hourglass", title: "Preparing the speech model",
                                    detail: "One-time setup, about 2 minutes", tone: .warning)),
            ]
            for (name, content) in states {
                let model = HUDModel()
                model.content = content
                model.visible = true
                let view = ZStack {
                    LinearGradient(colors: [Color(hex: 0xDCE6F5), Color(hex: 0xF4E9F0)], startPoint: .top, endPoint: .bottom)
                    HUDView(model: model, previewLevel: 0.7)
                }
                .frame(width: HUDController.size.width, height: HUDController.size.height)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage { write(image, to: dir.appendingPathComponent("hud-\(name).png")) }
            }
            print("Rendered to \(dir.path)")
            exit(0)
        }
    }

    private static func snapshot(_ window: NSWindow?, to url: URL) {
        // Render the layer tree: cacheDisplay skips layer-backed scroll content.
        if let number = window?.windowNumber, ProcessInfo.processInfo.environment["MURMUR_RENDER_SCREENCAPTURE"] != nil {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(number)", url.path]
            try? p.run(); p.waitUntilExit()
            return
        }
        guard let view = window?.contentView?.superview ?? window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let layer = view.layer,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if !view.isFlipped {
            // AppKit layers are already bottom-left origin; nothing to do.
        }
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

/// A tall window that isn't clamped to the screen, so whole pages fit in one snapshot.
@MainActor
private final class RenderWindowHost {
    let nav = Navigation()
    let window: NSWindow?

    init() {
        let w = UnclampedWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1500),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.contentViewController = NSHostingController(rootView: MainView(nav: nav).environmentObject(AppState.shared))
        w.setContentSize(NSSize(width: 900, height: 1500))
        w.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        w.orderFront(nil)
        window = w
    }
}

private final class UnclampedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension AppState {
    func setPreviewState(model: ModelStatus, mic: Bool, accessibility: Bool) {
        previewOverride(model: model, mic: mic, accessibility: accessibility)
    }
}
