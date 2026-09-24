import Cocoa
import ScreenCaptureKit

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Copie en direct d'une fenêtre, affichée dans un panneau flottant toujours au premier plan.
/// La copie est masquée (et la capture arrêtée) tant que la vraie fenêtre a le focus.
@MainActor
final class PinnedWindow: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var info: WindowInfo
    /// Zone gardée, en points, origine en haut à gauche de la fenêtre.
    private(set) var crop: CGRect?
    /// Vrai quand le panneau n'a plus la taille de la fenêtre (miniature ou recadrage).
    private(set) var customFrame = false
    private(set) var opacity: CGFloat = 1
    private(set) var ghost = false
    /// `appQuit` est vrai si l'app d'origine a été quittée : l'épingle est alors mise en attente.
    var onClose: ((PinnedWindow, _ appQuit: Bool) -> Void)?
    var onChange: (() -> Void)?

    private let panel: PinPanel
    private let mirror = MirrorView()
    private var stream: SCStream?
    private var capturing = false
    private var generation = 0
    private var wantsVisible = false
    private var hasFrame = false
    private var closed = false

    init(info: WindowInfo, restoring entry: PinEntry? = nil) {
        self.info = info
        panel = PinPanel(contentRect: Windows.cocoaRect(info.frame),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = mirror

        mirror.showBadge = Settings.showBadge
        mirror.aspect = { [weak self] in self?.aspect ?? 1 }
        mirror.onClick = { [weak self] in self?.focusRealWindow() }
        mirror.onUnpin = { [weak self] in self?.close() }
        mirror.onResizeEnd = { [weak self] in
            self?.customFrame = true
            self?.onChange?()
        }
        mirror.onCropSelected = { [weak self] r in self?.finishCrop(r) }
        mirror.onCropCancel = { [weak self] in self?.mirror.cropMode = false }
        mirror.onOpacityDelta = { [weak self] d in
            guard let self else { return }
            self.setOpacity(self.opacity + d)
        }
        mirror.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }

        if let entry {
            if let c = entry.crop?.intersection(CGRect(origin: .zero, size: info.frame.size)),
               c.width > 30, c.height > 30 {
                crop = c
            }
            if let f = entry.frame {
                panel.setFrame(f, display: false)
                customFrame = true
            }
            setOpacity(entry.opacity)
            setGhost(entry.ghost)
        }
    }

    var entry: PinEntry {
        PinEntry(bundleID: info.bundleID ?? "", appName: info.appName, title: info.title, crop: crop,
                 frame: customFrame ? panel.frame : nil, opacity: Double(opacity), ghost: ghost)
    }

    private var contentSize: CGSize { crop?.size ?? info.frame.size }
    private var aspect: CGFloat { contentSize.height > 0 ? contentSize.width / contentSize.height : 1 }

    // MARK: Visibilité

    func focusChanged(pid: pid_t, window: CGWindowID?) {
        // Fenêtre inconnue : on se rabat sur l'app entière.
        let realWindowFocused = pid == info.pid && (window == nil || window == info.id)
        if realWindowFocused && !mirror.cropMode { hide() } else { show() }
    }

    private func show() {
        guard !closed else { return }
        if !wantsVisible { refreshFromRealWindow() }
        wantsVisible = true
        // Tant qu'aucune image n'est arrivée, le panneau reste caché (sinon il serait vide).
        if hasFrame { panel.orderFrontRegardless() }
        startCapture()
    }

    private func hide() {
        wantsVisible = false
        panel.orderOut(nil)
        stopCapture()
    }

    /// Recale la copie sur la vraie fenêtre, qui a pu bouger ou changer de taille pendant qu'on travaillait dessus.
    private func refreshFromRealWindow() {
        guard let current = Windows.info(for: info.id) else { return }
        let sizeChanged = current.frame.size != info.frame.size
        info = current
        if let c = crop {
            let clipped = c.intersection(CGRect(origin: .zero, size: current.frame.size))
            if clipped.width > 30, clipped.height > 30 {
                crop = clipped
            } else {
                crop = nil
                customFrame = false
            }
        }
        if !customFrame {
            if current.onScreen { panel.setFrame(Windows.cocoaRect(current.frame), display: false) }
        } else if sizeChanged {
            fitPanelToAspect()
        }
        if sizeChanged { stream?.updateConfiguration(makeConfig()) { _ in } }
        onChange?()
    }

    private func fitPanelToAspect() {
        let f = panel.frame
        let h = f.width / aspect
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true)
    }

    private func focusRealWindow() {
        if !customFrame { Windows.move(info, toTopLeft: Windows.cgTopLeft(of: panel.frame)) }
        Windows.bringToFront(info)
        hide()
    }

    // MARK: Capture

    private func makeConfig() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 5
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Settings.frameRate))
        if let crop { c.sourceRect = crop }
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        c.width = max(2, Int(contentSize.width * scale))
        c.height = max(2, Int(contentSize.height * scale))
        return c
    }

    private func startCapture() {
        guard !capturing else { return }
        capturing = true
        generation += 1
        let gen = generation
        let id = info.id
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard gen == generation else { return }
                guard let scWindow = content.windows.first(where: { $0.windowID == id }) else {
                    throw NSError(domain: "Epingle", code: 1)
                }
                let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow),
                                 configuration: makeConfig(), delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                try await s.startCapture()
                guard gen == generation else {
                    try? await s.stopCapture()
                    return
                }
                stream = s
            } catch {
                guard gen == generation else { return }
                capturing = false
                closeAfterFailure()
            }
        }
    }

    private func stopCapture() {
        guard capturing else { return }
        capturing = false
        generation += 1
        stream?.stopCapture { _ in }
        stream = nil
    }

    private func closeAfterFailure() {
        // Laisse le temps à macOS de signaler la fermeture de l'app, pour distinguer « app quittée » de « fenêtre fermée ».
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.closed else { return }
            let app = NSRunningApplication(processIdentifier: self.info.pid)
            self.close(appQuit: app == nil || app?.isTerminated == true)
        }
    }

    func applySettings() {
        mirror.showBadge = Settings.showBadge
        stream?.updateConfiguration(makeConfig()) { _ in }
    }

    func close(appQuit: Bool = false) {
        guard !closed else { return }
        closed = true
        stopCapture()
        panel.orderOut(nil)
        panel.close()
        onClose?(self, appQuit)
        onClose = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        MainActor.assumeIsolated { display(surface) }
    }

    private func display(_ surface: IOSurfaceRef) {
        mirror.setContents(surface)
        if !hasFrame {
            hasFrame = true
            if wantsVisible { panel.orderFrontRegardless() }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.capturing = false
            self.stream = nil
            self.closeAfterFailure()
        }
    }

    // MARK: Opacité, mode fantôme, taille, recadrage

    private func setOpacity(_ value: CGFloat) {
        opacity = min(1, max(0.15, value))
        panel.alphaValue = opacity
        onChange?()
    }

    private func setGhost(_ on: Bool) {
        ghost = on
        panel.ignoresMouseEvents = on
        mirror.ghost = on
        onChange?()
    }

    private func beginCrop() {
        if ghost { setGhost(false) }
        crop = nil
        customFrame = false
        if let current = Windows.info(for: info.id) { info = current }
        panel.setFrame(Windows.cocoaRect(info.frame), display: true)
        stream?.updateConfiguration(makeConfig()) { _ in }
        mirror.cropMode = true
        show()
    }

    private func finishCrop(_ r: NSRect) {
        mirror.cropMode = false
        let b = mirror.bounds
        guard b.width > 0, b.height > 0 else { return }
        let sx = info.frame.width / b.width, sy = info.frame.height / b.height
        let c = CGRect(x: r.minX * sx, y: (b.height - r.maxY) * sy,
                       width: r.width * sx, height: r.height * sy).integral
            .intersection(CGRect(origin: .zero, size: info.frame.size))
        guard c.width > 30, c.height > 30 else { return }
        crop = c
        customFrame = true
        // Le panneau prend la place de la zone sélectionnée.
        let onScreen = panel.convertToScreen(mirror.convert(r, to: nil))
        let h = onScreen.width / aspect
        panel.setFrame(NSRect(x: onScreen.minX, y: onScreen.maxY - h, width: onScreen.width, height: h), display: true)
        stream?.updateConfiguration(makeConfig()) { _ in }
        onChange?()
    }

    private func removeCrop() {
        crop = nil
        customFrame = false
        panel.setFrame(Windows.cocoaRect(info.frame), display: true)
        stream?.updateConfiguration(makeConfig()) { _ in }
        onChange?()
    }

    private func realSize() {
        if let crop {
            let f = panel.frame
            panel.setFrame(NSRect(x: f.minX, y: f.maxY - crop.height, width: crop.width, height: crop.height), display: true)
        } else {
            customFrame = false
            panel.setFrame(Windows.cocoaRect(info.frame), display: true)
        }
        onChange?()
    }

    // MARK: Menu (clic droit sur la copie, et sous-menu dans la barre de menus)

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        add(m, "Mettre au premier plan", #selector(menuFront))
        add(m, "Désépingler", #selector(menuUnpin))
        m.addItem(.separator())
        add(m, "Mode fantôme (les clics traversent)", #selector(menuGhost)).state = ghost ? .on : .off
        let opacityItem = NSMenuItem(title: "Opacité", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for percent in [100, 85, 70, 50, 30] {
            let i = add(sub, "\(percent) %", #selector(menuOpacity(_:)))
            i.tag = percent
            i.state = Int((opacity * 100).rounded()) == percent ? .on : .off
        }
        opacityItem.submenu = sub
        m.addItem(opacityItem)
        m.addItem(.separator())
        if mirror.cropMode {
            add(m, "Annuler le recadrage", #selector(menuCancelCrop))
        } else {
            add(m, crop == nil ? "Recadrer…" : "Recadrer à nouveau…", #selector(menuCrop))
        }
        if crop != nil { add(m, "Supprimer le recadrage", #selector(menuUncrop)) }
        add(m, "Taille réelle", #selector(menuRealSize)).isEnabled = customFrame
        return m
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func menuFront() { focusRealWindow() }
    @objc private func menuUnpin() { close() }
    @objc private func menuGhost() { setGhost(!ghost) }
    @objc private func menuOpacity(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc private func menuCrop() { beginCrop() }
    @objc private func menuCancelCrop() { mirror.cropMode = false }
    @objc private func menuUncrop() { removeCrop() }
    @objc private func menuRealSize() { realSize() }
}
