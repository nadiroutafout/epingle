import Cocoa
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class PreferencesController: NSObject {
    private var window: NSWindow?

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Réglages d'Épingle"
        w.isReleasedWhenClosed = false

        let pinRecorder = ShortcutRecorder(Settings.pinShortcut) { Settings.pinShortcut = $0 }
        let searchRecorder = ShortcutRecorder(Settings.searchShortcut) { Settings.searchShortcut = $0 }

        let fps = NSPopUpButton()
        fps.addItems(withTitles: ["30 images/s (économe)", "60 images/s (plus fluide)"])
        fps.selectItem(at: Settings.frameRate >= 60 ? 1 : 0)
        fps.target = self
        fps.action = #selector(frameRateChanged(_:))

        let badge = NSButton(checkboxWithTitle: "Afficher la punaise sur les fenêtres épinglées",
                             target: self, action: #selector(badgeChanged(_:)))
        badge.state = Settings.showBadge ? .on : .off

        let login = NSButton(checkboxWithTitle: "Ouvrir Épingle à l'ouverture de session",
                             target: self, action: #selector(loginChanged(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let grid = NSGridView(views: [
            [label("Épingler la fenêtre active :"), pinRecorder],
            [label("Rechercher une fenêtre :"), searchRecorder],
            [label("Fluidité des copies :"), fps],
            [NSGridCell.emptyContentView, badge],
            [NSGridCell.emptyContentView, login],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        w.contentView = content
        return w
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    @objc private func frameRateChanged(_ sender: NSPopUpButton) {
        Settings.frameRate = sender.indexOfSelectedItem == 1 ? 60 : 30
    }

    @objc private func badgeChanged(_ sender: NSButton) {
        Settings.showBadge = sender.state == .on
    }

    @objc private func loginChanged(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Impossible de modifier l'ouverture à la connexion"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// Bouton qui enregistre un raccourci : cliquer, puis taper la combinaison (⎋ pour annuler).
final class ShortcutRecorder: NSButton {
    private var shortcut: Shortcut
    private let onChange: (Shortcut) -> Void
    private var monitor: Any?

    init(_ shortcut: Shortcut, onChange: @escaping (Shortcut) -> Void) {
        self.shortcut = shortcut
        self.onChange = onChange
        super.init(frame: .zero)
        bezelStyle = .push
        title = shortcut.display
        target = self
        action = #selector(record)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func record() {
        guard monitor == nil else { return }
        title = "Tapez le raccourci…"
        HotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let recorded = Shortcut(event: event)
            MainActor.assumeIsolated {
                if isEscape {
                    self.stop()
                } else if let recorded {
                    self.shortcut = recorded
                    self.onChange(recorded)
                    self.stop()
                } else {
                    NSSound.beep() // il faut au moins ⌃, ⌥ ou ⌘
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = shortcut.display
        HotKeys.shared.resume()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, monitor != nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}
