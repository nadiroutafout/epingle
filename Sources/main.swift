import Cocoa
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pins: [PinnedWindow] = []
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Épingle")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            MainActor.assumeIsolated { self?.pins.forEach { $0.appActivated(pid: pid) } }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            MainActor.assumeIsolated { self?.pins.filter { $0.info.pid == pid }.forEach { $0.close() } }
        }

        registerHotKey()
        requestPermissions()
        // Premier lancement depuis /Applications : activer l'ouverture à la connexion.
        let key = "loginItemConfigured"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    // MARK: Autorisations

    private var hasAccessibility: Bool { AXIsProcessTrusted() }
    private var hasScreenCapture: Bool { CGPreflightScreenCaptureAccess() }

    private func requestPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !hasScreenCapture { CGRequestScreenCaptureAccess() }
    }

    // MARK: Raccourci global ⌃⌥P

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.togglePinFrontmost() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4550_494E), id: 1) // 'EPIN'
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func togglePinFrontmost() {
        guard let w = Windows.frontmost() else { NSSound.beep(); return }
        if let existing = pins.first(where: { $0.info.id == w.id }) {
            existing.close()
        } else {
            pin(w)
        }
    }

    // MARK: Épinglage

    private func pin(_ info: WindowInfo) {
        guard !pins.contains(where: { $0.info.id == info.id }) else { return }
        let p = PinnedWindow(info: info)
        p.onClose = { [weak self] closed in self?.pins.removeAll { $0 === closed } }
        pins.append(p)
        Task {
            do {
                try await p.start()
                NSSound(named: "Pop")?.play()
            } catch {
                p.close()
                let alert = NSAlert()
                alert.messageText = "Impossible d'épingler « \(info.label) »"
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pinFront = NSMenuItem(title: "Épingler / désépingler la fenêtre active", action: #selector(togglePinFrontmost), keyEquivalent: "p")
        pinFront.keyEquivalentModifierMask = [.control, .option]
        pinFront.target = self
        menu.addItem(pinFront)

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Épinglées"))
            for p in pins {
                let item = NSMenuItem(title: p.info.label, action: #selector(unpinItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p
                item.state = .on
                item.toolTip = "Cliquer pour désépingler"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Fenêtres ouvertes"))
        let windows = Windows.list()
        if windows.isEmpty { menu.addItem(withTitle: "Aucune fenêtre", action: nil, keyEquivalent: "") }
        for w in windows {
            let item = NSMenuItem(title: truncate(w.label), action: nil, keyEquivalent: "")
            if let app = NSRunningApplication(processIdentifier: w.pid), let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            let sub = NSMenu()
            let front = NSMenuItem(title: "Mettre au premier plan", action: #selector(frontItem(_:)), keyEquivalent: "")
            front.target = self
            front.representedObject = w
            sub.addItem(front)
            let isPinned = pins.contains { $0.info.id == w.id }
            let pinItem = NSMenuItem(title: isPinned ? "Désépingler" : "Épingler (toujours au premier plan)",
                                     action: #selector(pinItem(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.representedObject = w
            sub.addItem(pinItem)
            item.submenu = sub
            menu.addItem(item)
        }

        if !hasAccessibility || !hasScreenCapture {
            menu.addItem(.separator())
            let perm = NSMenuItem(title: "⚠️ Autorisations manquantes…", action: #selector(openPrivacy), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Ouvrir à l'ouverture de session", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Quitter Épingle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func truncate(_ s: String) -> String { s.count > 70 ? String(s.prefix(67)) + "…" : s }

    @objc private func frontItem(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? WindowInfo else { return }
        Windows.bringToFront(w)
    }

    @objc private func pinItem(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? WindowInfo else { return }
        if let existing = pins.first(where: { $0.info.id == w.id }) { existing.close() } else { pin(w) }
    }

    @objc private func unpinItem(_ sender: NSMenuItem) {
        (sender.representedObject as? PinnedWindow)?.close()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossible de modifier l'ouverture à la connexion"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func openPrivacy() {
        requestPermissions()
        let pane = hasAccessibility ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
