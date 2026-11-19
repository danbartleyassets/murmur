import SwiftUI
import AppKit
import os

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu().environmentObject(state)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel("Murmur")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { WindowManager.shared.showMain(page: .general) }
                    .keyboardShortcut(",")
            }
        }
    }

    private var menuBarSymbol: String {
        switch state.phase {
        case .listening: return state.locked ? "lock.fill" : "mic.fill"
        case .transcribing, .thinking: return "ellipsis"
        case .idle: return settings.enabled ? "waveform" : "pause.fill"
        }
    }
}

private struct MenuBarMenu: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var history = History.shared

    var body: some View {
        Text(statusLine)
        if let last = history.items.first {
            Button("Copy Last Dictation") { state.copyLastDictation() }
                .help(last.text)
        }
        Divider()
        Toggle("Pause Dictation", isOn: Binding(get: { !settings.enabled }, set: { settings.enabled = !$0 }))
        Divider()
        Button("Open Murmur") { WindowManager.shared.showMain() }
        Button("Settings…") { WindowManager.shared.showMain(page: .general) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch state.model {
        case .downloading(let f): return "Downloading speech model… \(Int(f * 100))%"
        case .preparing(let first): return first ? "Preparing speech model (one-time)…" : "Loading speech model…"
        case .failed: return "Speech model didn't load"
        case .idle: return "Starting…"
        case .ready:
            if !state.micGranted || !state.accessibilityGranted { return "Finish setup in Murmur" }
            if state.inputDeviceName == nil { return "No microphone connected" }
            if !settings.enabled { return "Paused" }
            return "Ready — double-tap \(settings.trigger.symbol) and hold"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Login-item launches stay quiet in the menu bar.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GoogleSans.register()
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            SettingsStore.shared.appearance.apply()
            AppIconManager.shared.start()
            if DevHooks.runIfRequested() { return }
            AppState.shared.start()
            MainThreadWatchdog.shared.start()
            let needsSetup = !Permissions.microphoneGranted || !Permissions.accessibilityGranted
            if !launchedAtLogin || needsSetup { WindowManager.shared.showMain() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WindowManager.shared.showMain() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppIconManager.shared.stop()
            AppState.shared.stop()
        }
    }
}

/// Owns the main window and switches the Dock icon on only while it's open.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    let nav = Navigation()
    private(set) var window: NSWindow?

    func showMain(page: Page? = nil) {
        if let page { nav.page = page }
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)
        // The policy change lands on the next pass of the run loop; activating in
        // the same pass can leave the window behind other apps, or off screen.
        // Changing from a menu-bar app to a regular app also creates a fresh Dock
        // tile, so reapply the system-selected icon once it exists.
        DispatchQueue.main.async { [weak self] in
            AppIconManager.shared.refreshDockTile()
            guard let window = self?.window else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func build() {
        let root = MainView(nav: nav).environmentObject(AppState.shared)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Murmur"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 700))
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.setFrameAutosaveName("MurmurMain")
        if window.frame.origin == .zero { window.center() }
        window.delegate = self
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app once the window is gone, and drop the window so
        // its views stop updating in the background. It's rebuilt on the next open.
        DispatchQueue.main.async { [weak self] in
            NSApp.setActivationPolicy(.accessory)
            if self?.window?.isVisible == false {
                self?.window?.delegate = nil
                self?.window?.contentViewController = nil
                self?.window = nil
            }
        }
    }
}

/// Logs whenever the main thread stops answering, so a freeze leaves a trace in
/// `log show --predicate 'subsystem == "com.danbartley.murmur"'` instead of a mystery.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private let queue = DispatchQueue(label: "com.danbartley.murmur.watchdog", qos: .utility)
    private let pending = OSAllocatedUnfairLock<Date?>(initialState: nil)
    private var timer: DispatchSourceTimer?
    private var reported = false

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        if let sent = pending.withLock({ $0 }) {
            let stalled = Date().timeIntervalSince(sent)
            if stalled > 3, !reported {
                reported = true
                Log.app.fault("Main thread unresponsive for \(stalled, format: .fixed(precision: 1))s")
            }
            return
        }
        if reported { Log.app.notice("Main thread responsive again"); reported = false }
        pending.withLock { $0 = Date() }
        DispatchQueue.main.async { [weak self] in self?.pending.withLock { $0 = nil } }
    }
}
