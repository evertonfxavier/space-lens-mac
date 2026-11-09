import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel

    override init() {
        #if SNAPSHOT_TOOLS
            // The screenshot harness never touches the real home folder or the real settings.
            if let dir = ProcessInfo.processInfo.environment["SPACELENS_SNAPSHOT_DIR"] {
                let sandbox = URL(fileURLWithPath: dir).appendingPathComponent("demo-home")
                try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
                model = AppModel(
                    home: sandbox.path, storeDirectory: URL(fileURLWithPath: dir).appendingPathComponent("demo-store"),
                    startTimers: false)
                super.init()
                return
            }
        #endif
        model = AppModel()
        super.init()
    }
    private(set) var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()
        if Self.launchedAtLogin {
            // Started by "open at login": live in the menu bar, no window, no Dock icon.
            NSApp.setActivationPolicy(.accessory)
        } else {
            showMainWindow()
        }
        #if SNAPSHOT_TOOLS
            runSnapshotsIfRequested()
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)
    }

    // MARK: Windows

    @objc func showMainWindow() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let controller = NSHostingController(rootView: RootView().environmentObject(model))
            let w = NSWindow(contentViewController: controller)
            w.title = "SpaceLens"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 1120, height: 740))
            w.minSize = NSSize(width: 940, height: 600)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("SpaceLensMain")
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView().environmentObject(model))
            let w = NSWindow(contentViewController: controller)
            w.title = "Ajustes do SpaceLens"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu bar app once no window is left, so the Dock icon does not linger.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let anyVisible = [self.window, self.settingsWindow].contains { $0?.isVisible == true }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.setAccessibilityLabel("SpaceLens")
        popover.behavior = .transient
        let controller = NSHostingController(
            rootView: MenuBarView(
                openMain: { [weak self] in self?.showMainWindow() },
                openSettings: { [weak self] in self?.showSettings() },
                quit: { NSApp.terminate(nil) }
            ).environmentObject(model))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        model.$usage.combineLatest(model.$settings).receive(on: RunLoop.main).sink { [weak self] _, _ in
            self?.refreshStatusItem()
        }.store(in: &cancellables)
        refreshStatusItem()
    }

    func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let low = model.isLowOnSpace
        let image = NSImage(
            systemSymbolName: low ? "exclamationmark.triangle.fill" : "internaldrive",
            accessibilityDescription: "Espaço em disco")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.contentTintColor = low ? .systemRed : nil
        if model.settings.showFreeSpaceInMenuBar {
            button.attributedTitle = NSAttributedString(
                string: " " + model.freeSpaceText,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: low ? NSColor.systemRed : NSColor.labelColor,
                ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = "SpaceLens · \(model.freeSpaceText) livres"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.tick()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Main menu

    private func buildMainMenu() {
        let main = NSMenu()
        func add(
            _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
            mods: NSEvent.ModifierFlags = .command
        ) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
        }

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        appItem.submenu = app
        add(app, "Sobre o SpaceLens", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Ajustes…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        add(app, "Ocultar SpaceLens", #selector(NSApplication.hide(_:)), "h")
        add(app, "Sair do SpaceLens", #selector(NSApplication.terminate(_:)), "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Editar")
        editItem.submenu = edit
        add(edit, "Copiar", #selector(NSText.copy(_:)), "c")
        add(edit, "Selecionar tudo", #selector(NSText.selectAll(_:)), "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Janela")
        windowItem.submenu = windowMenu
        add(windowMenu, "Minimizar", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Fechar", #selector(NSWindow.performClose(_:)), "w")
        let show = windowMenu.addItem(withTitle: "SpaceLens", action: #selector(showMainWindow), keyEquivalent: "0")
        show.target = self
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

#if SNAPSHOT_TOOLS
    extension AppDelegate {
        /// `SPACELENS_SNAPSHOT_DIR=/some/dir` loads demo data, saves a PNG of each screen and quits.
        func runSnapshotsIfRequested() {
            guard let dir = ProcessInfo.processInfo.environment["SPACELENS_SNAPSHOT_DIR"] else { return }
            Task { @MainActor in
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                model.loadDemo()
                @MainActor func shot(_ view: NSView?, _ name: String) {
                    guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                for pane in Pane.allCases {
                    model.section = pane
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    shot(window?.contentView, pane.rawValue)
                }
                model.section = .explorer
                model.explorerMap = true
                try? await Task.sleep(nanoseconds: 900_000_000)
                shot(window?.contentView, "explorer-map")

                let hosting = NSHostingView(
                    rootView: MenuBarView(openMain: {}, openSettings: {}, quit: {}).environmentObject(model))
                let size = hosting.fittingSize
                let offscreen = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                    defer: false)
                offscreen.contentView = hosting
                offscreen.backgroundColor = .windowBackgroundColor
                hosting.frame = NSRect(origin: .zero, size: size)
                offscreen.orderBack(nil)
                try? await Task.sleep(nanoseconds: 400_000_000)
                shot(hosting, "menubar")

                let settings = NSHostingView(rootView: SettingsView().environmentObject(model))
                let ssize = settings.fittingSize
                let sw = NSWindow(
                    contentRect: NSRect(origin: .zero, size: ssize), styleMask: [.titled], backing: .buffered,
                    defer: false)
                sw.contentView = settings
                sw.orderBack(nil)
                try? await Task.sleep(nanoseconds: 400_000_000)
                shot(settings, "settings")
                NSApp.terminate(nil)
            }
        }
    }
#endif
