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
                    startTimers: false,
                    languageOverride: ProcessInfo.processInfo.environment["SPACELENS_LANGUAGE"]
                        .flatMap { AppLanguage(rawValue: $0) })
                super.init()
                return
            }
        #endif
        model = AppModel()
        super.init()
    }
    private(set) var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        configurePopover()
        model.$languageRevision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.languageChanged()
        }.store(in: &cancellables)
        model.$usage.combineLatest(model.$settings).receive(on: RunLoop.main).sink { [weak self] _, _ in
            self?.refreshStatusItem()
        }.store(in: &cancellables)
        // The menu bar item can be switched off in the settings; the first value builds it at launch.
        let visibility = model.$settings.map(\.showMenuBarItem).removeDuplicates()
        visibility.receive(on: RunLoop.main).sink { [weak self] visible in
            self?.setMenuBarItem(visible: visible)
        }.store(in: &cancellables)
        visibility.dropFirst().receive(on: RunLoop.main).sink { [weak self] visible in
            self?.updateActivationPolicy(menuBarVisible: visible)
        }.store(in: &cancellables)
        if Self.launchedAtLogin {
            // Started by "open at login": live in the menu bar, no window, no Dock icon. Without a menu bar item
            // the Dock icon is the only way back in, so it stays.
            if model.settings.showMenuBarItem { NSApp.setActivationPolicy(.accessory) }
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

    /// Settings and About are panes of the main window, so the menu bar panel, ⌘, and the app menu all land there.
    @objc func showSettings() { show(.settings) }

    @objc func showAbout() { show(.about) }

    private func show(_ pane: Pane) {
        model.section = pane
        showMainWindow()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateActivationPolicy(menuBarVisible: self.model.settings.showMenuBarItem)
        }
    }

    /// A pure menu bar app once no window is left, so the Dock icon does not linger. With the menu bar item
    /// switched off the app keeps its Dock icon: it would otherwise be unreachable.
    private func updateActivationPolicy(menuBarVisible: Bool) {
        let anyVisible = window?.isVisible == true
        NSApp.setActivationPolicy(menuBarVisible && !anyVisible ? .accessory : .regular)
    }

    // MARK: Menu bar

    private func setMenuBarItem(visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.setAccessibilityLabel("SpaceLens")
            refreshStatusItem()
        } else if !visible, let item = statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        let controller = NSHostingController(
            rootView: MenuBarView(
                openMain: { [weak self] in self?.showMainWindow() },
                openSettings: { [weak self] in self?.showSettings() },
                quit: { NSApp.terminate(nil) }
            ).environmentObject(model))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
    }

    func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let low = model.isLowOnSpace
        let image = NSImage(
            systemSymbolName: low ? "exclamationmark.triangle.fill" : "internaldrive",
            accessibilityDescription: L("Espaço em disco"))
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
        button.toolTip = L("SpaceLens · %@ livres", model.freeSpaceText)
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

    private func languageChanged() {
        buildMainMenu()
        refreshStatusItem()
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
        let about = app.addItem(withTitle: L("Sobre o SpaceLens"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        app.addItem(.separator())
        let settings = app.addItem(withTitle: L("Ajustes…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        add(app, L("Ocultar SpaceLens"), #selector(NSApplication.hide(_:)), "h")
        add(app, L("Sair do SpaceLens"), #selector(NSApplication.terminate(_:)), "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L("Editar"))
        editItem.submenu = edit
        add(edit, L("Copiar"), #selector(NSText.copy(_:)), "c")
        add(edit, L("Selecionar tudo"), #selector(NSText.selectAll(_:)), "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: L("Janela"))
        windowItem.submenu = windowMenu
        add(windowMenu, L("Minimizar"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, L("Fechar"), #selector(NSWindow.performClose(_:)), "w")
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
                model.fullDiskAccess = true  // the demo has nothing to say about the real permission
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                if ProcessInfo.processInfo.environment["SPACELENS_DEMO_UPDATE"] != nil {
                    model.availableUpdate = ReleaseInfo(
                        version: AppVersion("0.2.0")!, tag: "v0.2.0", name: "SpaceLens 0.2.0",
                        pageURL: URL(string: "https://github.com/evertonfxavier/space-lens-mac/releases/tag/v0.2.0")!,
                        downloadURL: nil, notes: "", publishedAt: nil)
                }
                @MainActor func shot(_ view: NSView?, _ name: String) {
                    // The real window composited by the window server, so the sidebar selection and the
                    // translucent materials look like they do on screen. Falls back to a plain view capture.
                    if let view, let main = window, view === main.contentView {
                        let number = main.windowNumber
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        process.arguments = ["-x", "-o", "-l", "\(number)", "\(dir)/\(name).png"]
                        try? process.run()
                        process.waitUntilExit()
                        if process.terminationStatus == 0 { return }
                    }
                    guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                for pane in Pane.allCases {
                    model.section = pane
                    model.fullDiskAccess = true
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    shot(window?.contentView, pane.rawValue)
                }
                model.section = .explorer
                model.explorerMap = true
                model.fullDiskAccess = true
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

                NSApp.terminate(nil)
            }
        }
    }
#endif
