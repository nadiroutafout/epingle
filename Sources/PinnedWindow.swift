import Cocoa
import ScreenCaptureKit

/// Copie en direct d'une fenêtre, affichée dans un panneau flottant toujours au premier plan.
/// Un clic sur la copie amène la vraie fenêtre à cet endroit et lui donne le focus.
@MainActor
final class PinnedWindow: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var info: WindowInfo
    private let panel: NSPanel
    private let mirror = MirrorView()
    private var stream: SCStream?
    private var config = SCStreamConfiguration()
    var onClose: ((PinnedWindow) -> Void)?

    init(info: WindowInfo) {
        self.info = info
        panel = NSPanel(contentRect: Windows.cocoaRect(info.frame),
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
        mirror.onClick = { [weak self] in self?.focusRealWindow() }
        mirror.onUnpin = { [weak self] in self?.close() }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == info.id }) else {
            throw NSError(domain: "Epingle", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Fenêtre introuvable (autorisation Enregistrement de l'écran ?)"])
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        applySize()
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        try await s.startCapture()
        stream = s
        appActivated(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }

    func close() {
        stream?.stopCapture { _ in }
        stream = nil
        panel.orderOut(nil)
        panel.close()
        onClose?(self)
        onClose = nil
    }

    /// La copie est masquée tant que l'app d'origine est active : on travaille alors sur la vraie fenêtre.
    func appActivated(pid: pid_t) {
        if pid == info.pid {
            panel.orderOut(nil)
        } else {
            syncWithRealWindow()
            panel.orderFrontRegardless()
        }
    }

    private func syncWithRealWindow() {
        guard let (current, onScreen) = Windows.info(for: info.id), onScreen else { return }
        let sizeChanged = current.frame.size != info.frame.size
        info = current
        panel.setFrame(Windows.cocoaRect(current.frame), display: true)
        if sizeChanged {
            applySize()
            stream?.updateConfiguration(config) { _ in }
        }
    }

    private func applySize() {
        let scale = panel.screen?.backingScaleFactor ?? 2
        config.width = Int(info.frame.width * scale)
        config.height = Int(info.frame.height * scale)
    }

    private func focusRealWindow() {
        Windows.move(info, toTopLeft: Windows.cgTopLeft(of: panel.frame))
        Windows.bringToFront(info)
        panel.orderOut(nil)
    }

    // MARK: SCStreamOutput / SCStreamDelegate (appelés sur la file principale)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        MainActor.assumeIsolated { mirror.layer?.contents = surface }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // La fenêtre d'origine a été fermée (ou la capture interrompue).
        DispatchQueue.main.async { self.close() }
    }
}

final class MirrorView: NSView {
    var onClick: (() -> Void)?
    var onUnpin: (() -> Void)?
    private var dragStart = NSPoint.zero
    private var originStart = NSPoint.zero
    private var dragged = false
    private let badge = NSTextField(labelWithString: "📌")

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect

        badge.font = .systemFont(ofSize: 14)
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Toute la vue reçoit les clics, y compris sur la punaise (gérée dans mouseUp).
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    private func isOnBadge(_ event: NSEvent) -> Bool {
        badge.frame.insetBy(dx: -8, dy: -6).contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        originStart = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        if abs(dx) + abs(dy) > 3 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: originStart.x + dx, y: originStart.y + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        if isOnBadge(event) { onUnpin?() } else { onClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Désépingler", action: #selector(unpin), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func unpin() { onUnpin?() }
}
