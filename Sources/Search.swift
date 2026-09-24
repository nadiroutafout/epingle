import Cocoa
import Carbon.HIToolbox

final class KeyPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onCommandReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let isReturn = e.keyCode == UInt16(kVK_Return) || e.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        if isReturn && e.modifierFlags.contains(.command) {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
}

/// Barre de recherche façon Spotlight : ↩ met la fenêtre au premier plan, ⌘↩ l'épingle.
@MainActor
final class SearchController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onChoose: ((WindowInfo, _ pin: Bool) -> Void)?

    private let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                                 styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                 backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [WindowInfo] = []
    private var results: [WindowInfo] = []
    private var pinned: Set<CGWindowID> = []

    override init() {
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onResignKey = { [weak self] in self?.panel.orderOut(nil) }
        panel.onCommandReturn = { [weak self] in self?.choose(pin: true) }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        panel.contentView = effect

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        field.placeholderString = "Rechercher une fenêtre…"
        field.font = .systemFont(ofSize: 22)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        let separator = NSBox()
        separator.boxType = .separator

        table.addTableColumn(NSTableColumn(identifier: .init("fenetre")))
        table.headerView = nil
        table.rowHeight = 38
        table.style = .inset
        table.backgroundColor = .clear
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let help = NSTextField(labelWithString: "↩ Mettre au premier plan      ⌘↩ Épingler / désépingler      ⎋ Fermer")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        for v in [icon, field, separator, scroll, help] {
            v.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: help.topAnchor, constant: -8),
            help.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            help.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
        ])
    }

    func toggle(pinned: Set<CGWindowID>) {
        if panel.isVisible { panel.orderOut(nil) } else { present(pinned: pinned) }
    }

    private func present(pinned: Set<CGWindowID>) {
        self.pinned = pinned
        all = Windows.list(includeOffscreen: true)
        field.stringValue = ""
        filter()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2,
                                         y: vf.minY + vf.height * 0.62 - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    // MARK: Filtrage

    private func filter() {
        let query = normalize(field.stringValue)
        if query.isEmpty {
            results = all
        } else {
            results = all.enumerated()
                .compactMap { i, w in score(query, normalize(w.appName + " " + w.title)).map { (w, $0, i) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
                .map(\.0)
        }
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Texte contenu tel quel : meilleur score ; sinon lettres dans l'ordre (« gchr » → « Google Chrome »).
    private func score(_ query: String, _ text: String) -> Int? {
        if let r = text.range(of: query) {
            return 10_000 - text.distance(from: text.startIndex, to: r.lowerBound)
        }
        var i = text.startIndex
        var gaps = 0
        for ch in query {
            guard let found = text[i...].firstIndex(of: ch) else { return nil }
            gaps += text.distance(from: i, to: found)
            i = text.index(after: found)
        }
        return 5_000 - gaps
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), results.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func choose(pin: Bool) {
        let row = table.selectedRow
        guard results.indices.contains(row) else { return }
        let w = results[row]
        // Les fenêtres masquées ne s'épinglent pas.
        if pin && !w.onScreen && !pinned.contains(w.id) {
            NSSound.beep()
            return
        }
        panel.orderOut(nil)
        onChoose?(w, pin)
    }

    @objc private func doubleClicked() { choose(pin: false) }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            choose(pin: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil)
        default: return false
        }
        return true
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let w = results[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSRunningApplication(processIdentifier: w.pid)?.icon ?? NSImage())
        let title = NSTextField(labelWithString: w.title.isEmpty ? w.appName : w.title)
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        var detail = w.appName
        if pinned.contains(w.id) { detail = "📌 " + detail }
        if !w.onScreen { detail += " · masquée (réduite ou sur un autre bureau)" }
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        for v in [icon, title, sub] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        return cell
    }
}
