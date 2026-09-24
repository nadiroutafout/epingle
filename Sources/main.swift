import Cocoa
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pins: [PinnedWindow] = []
    /// Épingles à restaurer dès que leur fenêtre réapparaît (relance d'Épingle ou de l'app d'origine).
    private var pending: [PinEntry] = []
    private let focus = FocusTracker()
    private let search = SearchController()
    private let preferences = PreferencesController()
    private var restoreTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Épingle")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        focus.onChange = { [weak self] pid, window in
            self?.pins.forEach { $0.focusChanged(pid: pid, window: window) }
        }
        focus.start()
        search.onChoose = { [weak self] window, pin in
            if pin { self?.togglePin(window) } else { Windows.bringToFront(window) }
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            MainActor.assumeIsolated {
                self?.pins.filter { $0.info.pid == pid }.forEach { $0.close(appQuit: true) }
            }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // Laisse à l'app le temps d'ouvrir ses fenêtres.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.restorePending() }
        }
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerHotKeys()
                self?.pins.forEach { $0.applySettings() }
            }
        }

        registerHotKeys()
        requestPermissions()

        // Premier lancement depuis /Applications : activer l'ouverture à la connexion.
        let key = "loginItemConfigured"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }

        pending = PinStore.load()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.restorePending() }
    }

    private func registerHotKeys() {
        HotKeys.shared.register(id: 1, Settings.pinShortcut) { [weak self] in self?.togglePinFrontmost() }
        HotKeys.shared.register(id: 2, Settings.searchShortcut) { [weak self] in self?.showSearch() }
    }

    // MARK: Autorisations

    private var hasAccessibility: Bool { AXIsProcessTrusted() }
    private var hasScreenCapture: Bool { CGPreflightScreenCaptureAccess() }

    private func requestPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !hasScreenCapture { CGRequestScreenCaptureAccess() }
    }

    @objc private func openPrivacy() {
        requestPermissions()
        let pane = hasAccessibility ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private func askForScreenCapture() {
        let alert = NSAlert()
        alert.messageText = "Autorisation « Enregistrement de l'écran » nécessaire"
        alert.informativeText = "Épingle en a besoin pour afficher la copie des fenêtres épinglées. Activez Épingle dans les réglages, puis relancez l'app."
        alert.addButton(withTitle: "Ouvrir les réglages")
        alert.addButton(withTitle: "Annuler")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openPrivacy() }
    }

    // MARK: Épinglage

    private func isPinned(_ id: CGWindowID) -> Bool { pins.contains { $0.info.id == id } }

    @objc private func togglePinFrontmost() {
        let (pid, windowID) = focus.current()
        let target = windowID.flatMap { Windows.info(for: $0) } ?? Windows.list().first { $0.pid == pid }
        guard let w = target, w.pid != getpid() else { NSSound.beep(); return }
        togglePin(w)
    }

    private func togglePin(_ w: WindowInfo) {
        if let p = pins.first(where: { $0.info.id == w.id }) { p.close() } else { pin(w) }
    }

    private func pin(_ info: WindowInfo, restoring entry: PinEntry? = nil) {
        guard !isPinned(info.id) else { return }
        guard hasScreenCapture else { askForScreenCapture(); return }
        // Les fenêtres masquées (réduites ou sur un autre bureau) ne s'épinglent pas.
        guard info.onScreen || entry != nil else { NSSound.beep(); return }
        let p = PinnedWindow(info: info, restoring: entry)
        p.onClose = { [weak self] closed, appQuit in self?.pinClosed(closed, appQuit: appQuit) }
        p.onChange = { [weak self] in self?.save() }
        pins.append(p)
        save()
        let current = focus.current()
        p.focusChanged(pid: current.pid, window: current.window)
        if entry == nil { NSSound(named: "Pop")?.play() }
    }

    private func pinClosed(_ p: PinnedWindow, appQuit: Bool) {
        pins.removeAll { $0 === p }
        if appQuit {
            pending.append(p.entry)
            updateRestoreTimer()
        }
        save()
    }

    private func save() {
        PinStore.save(pins.map(\.entry) + pending)
    }

    private func restorePending() {
        guard !pending.isEmpty, hasScreenCapture else { return }
        let windows = Windows.list(includeOffscreen: true)
        var remaining: [PinEntry] = []
        for e in pending {
            let candidates = windows.filter { $0.bundleID == e.bundleID && !isPinned($0.id) }
            // Même titre de préférence ; sinon la seule fenêtre de l'app.
            if let w = candidates.first(where: { $0.title == e.title }) ?? (candidates.count == 1 ? candidates.first : nil) {
                pin(w, restoring: e)
            } else {
                remaining.append(e)
            }
        }
        pending = remaining
        save()
        updateRestoreTimer()
    }

    private func updateRestoreTimer() {
        if pending.isEmpty {
            restoreTimer?.invalidate()
            restoreTimer = nil
        } else if restoreTimer == nil {
            restoreTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.restorePending() }
            }
        }
    }

    @objc private func showSearch() {
        search.toggle(pinned: Set(pins.map(\.info.id)))
    }

    @objc private func showPreferences() { preferences.show() }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addAction(menu, "Rechercher une fenêtre…", #selector(showSearch), shortcut: Settings.searchShortcut)
        addAction(menu, "Épingler / désépingler la fenêtre active", #selector(togglePinFrontmost), shortcut: Settings.pinShortcut)

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Épinglées"))
            for p in pins {
                let item = NSMenuItem(title: truncate(p.info.label), action: nil, keyEquivalent: "")
                item.image = appIcon(p.info.pid)
                item.submenu = p.makeMenu()
                menu.addItem(item)
            }
        }

        if !pending.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "En attente de réouverture"))
            for (i, e) in pending.enumerated() {
                let item = addAction(menu, truncate(e.label), #selector(forgetPending(_:)))
                item.tag = i
                item.toolTip = "Sera réépinglée quand la fenêtre réapparaîtra. Cliquer pour l'oublier."
            }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Fenêtres"))
        let windows = Windows.list(includeOffscreen: true)
        if windows.isEmpty { menu.addItem(withTitle: "Aucune fenêtre", action: nil, keyEquivalent: "") }
        for w in windows {
            let item = NSMenuItem(title: truncate(w.label) + (w.onScreen ? "" : " (masquée)"), action: nil, keyEquivalent: "")
            item.image = appIcon(w.pid)
            let sub = NSMenu()
            addAction(sub, "Mettre au premier plan", #selector(frontItem(_:))).representedObject = w
            if isPinned(w.id) {
                addAction(sub, "Désépingler", #selector(pinItem(_:))).representedObject = w
            } else if w.onScreen {
                addAction(sub, "Épingler (toujours au premier plan)", #selector(pinItem(_:))).representedObject = w
            }
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if !hasAccessibility || !hasScreenCapture {
            addAction(menu, "⚠️ Autorisations manquantes…", #selector(openPrivacy))
        }
        let prefs = addAction(menu, "Réglages…", #selector(showPreferences))
        prefs.keyEquivalent = ","
        menu.addItem(withTitle: "Quitter Épingle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    private func addAction(_ menu: NSMenu, _ title: String, _ action: Selector, shortcut: Shortcut? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.menuKeyEquivalent ?? "")
        if let shortcut { item.keyEquivalentModifierMask = shortcut.menuModifiers }
        item.target = self
        menu.addItem(item)
        return item
    }

    private func appIcon(_ pid: pid_t) -> NSImage? {
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func truncate(_ s: String) -> String { s.count > 70 ? String(s.prefix(67)) + "…" : s }

    @objc private func frontItem(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? WindowInfo else { return }
        Windows.bringToFront(w)
    }

    @objc private func pinItem(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? WindowInfo else { return }
        togglePin(w)
    }

    @objc private func forgetPending(_ sender: NSMenuItem) {
        guard pending.indices.contains(sender.tag) else { return }
        pending.remove(at: sender.tag)
        save()
        updateRestoreTimer()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
