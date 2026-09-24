import Cocoa

/// Affiche la copie d'une fenêtre et gère la souris : clic, déplacement, redimensionnement par les coins,
/// recadrage, opacité (⌥ + molette) et clic sur la punaise.
final class MirrorView: NSView {
    var onClick: (() -> Void)?
    var onUnpin: (() -> Void)?
    var onResizeEnd: (() -> Void)?
    var onCropSelected: ((NSRect) -> Void)?
    var onCropCancel: (() -> Void)?
    var onOpacityDelta: ((CGFloat) -> Void)?
    var menuProvider: (() -> NSMenu)?
    /// Rapport largeur / hauteur à conserver pendant le redimensionnement.
    var aspect: () -> CGFloat = { 1 }

    var showBadge = true { didSet { badge.isHidden = !showBadge } }
    var ghost = false { didSet { badge.alphaValue = ghost ? 0.35 : 1 } }
    var cropMode = false {
        didSet {
            hint.isHidden = !cropMode
            selection.path = nil
        }
    }

    private enum Corner { case topLeft, bottomLeft, bottomRight }
    private enum Drag { case none, move, resize(Corner), crop(NSPoint) }

    private let content = CALayer()
    private let selection = CAShapeLayer()
    private let badge = NSTextField(labelWithString: "📌")
    private let hint = NSTextField(labelWithString: "  Dessinez la zone à garder  ")
    private var drag = Drag.none
    private var dragged = false
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var selectionRect = NSRect.zero
    private let cornerSize: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        content.contentsGravity = .resizeAspect
        layer?.addSublayer(content)
        selection.fillColor = NSColor.white.withAlphaComponent(0.18).cgColor
        selection.strokeColor = NSColor.systemYellow.cgColor
        selection.lineWidth = 2
        selection.lineDashPattern = [6, 4]
        layer?.addSublayer(selection)

        badge.font = .systemFont(ofSize: 14)
        hint.font = .boldSystemFont(ofSize: 15)
        hint.textColor = .white
        hint.drawsBackground = true
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        hint.isHidden = true
        for v in [badge, hint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 40),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        selection.frame = bounds
        CATransaction.commit()
    }

    func setContents(_ surface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = surface
        CATransaction.commit()
    }

    // MARK: Souris

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Toute la vue reçoit les clics, y compris sur la punaise (gérée dans mouseUp).
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    private func location(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    private func isOnBadge(_ event: NSEvent) -> Bool {
        showBadge && badge.frame.insetBy(dx: -8, dy: -6).contains(location(event))
    }

    private func corner(at p: NSPoint) -> Corner? {
        let b = bounds, s = cornerSize
        if p.x < s && p.y < s { return .bottomLeft }
        if p.x > b.maxX - s && p.y < s { return .bottomRight }
        if p.x < s && p.y > b.maxY - s { return .topLeft }
        return nil // le coin en haut à droite est réservé à la punaise
    }

    override func mouseMoved(with event: NSEvent) {
        if cropMode { NSCursor.crosshair.set(); return }
        guard let c = corner(at: location(event)) else { NSCursor.arrow.set(); return }
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch c {
            case .topLeft: .topLeft
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            NSCursor.frameResize(position: position, directions: .all).set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
        dragged = false
        let p = location(event)
        if cropMode {
            drag = .crop(p)
        } else if let c = corner(at: p) {
            drag = .resize(c)
        } else {
            drag = .move
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        if abs(dx) + abs(dy) > 3 { dragged = true }
        guard dragged else { return }
        switch drag {
        case .move:
            window?.setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
        case .resize(let c):
            window?.setFrame(resizedFrame(c, dx: dx), display: true)
        case .crop(let start):
            let p = location(event)
            selectionRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                   width: abs(p.x - start.x), height: abs(p.y - start.y)).intersection(bounds)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selection.path = CGPath(rect: selectionRect, transform: nil)
            CATransaction.commit()
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        switch drag {
        case .move:
            guard !dragged else { return }
            if isOnBadge(event) { onUnpin?() } else { onClick?() }
        case .resize:
            if dragged { onResizeEnd?() }
        case .crop:
            if dragged, selectionRect.width > 20, selectionRect.height > 20 {
                onCropSelected?(selectionRect)
            } else {
                onCropCancel?()
            }
        case .none:
            break
        }
    }

    /// Redimensionne depuis un coin en gardant le coin opposé fixe et les proportions.
    private func resizedFrame(_ c: Corner, dx: CGFloat) -> NSRect {
        let a = max(aspect(), 0.05)
        let f = startFrame
        let right = c == .bottomRight
        let w = max(120, f.width + (right ? dx : -dx))
        let h = w / a
        return NSRect(x: right ? f.minX : f.maxX - w,
                      y: c == .topLeft ? f.minY : f.maxY - h,
                      width: w, height: h)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.005 : event.scrollingDeltaY * 0.05
        onOpacityDelta?(delta)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
