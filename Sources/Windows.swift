import Cocoa
import ApplicationServices

// API privée mais stable, utilisée par la plupart des gestionnaires de fenêtres
// pour relier un AXUIElement à son CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    /// Coordonnées CoreGraphics (origine en haut à gauche de l'écran principal).
    let frame: CGRect
    /// Faux pour une fenêtre réduite, masquée ou sur un autre bureau.
    let onScreen: Bool

    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
    var bundleID: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
}

enum Windows {
    /// Fenêtres des apps, de la plus en avant à la plus en arrière. Avec `includeOffscreen`,
    /// les fenêtres réduites ou sur un autre bureau sont ajoutées à la fin.
    static func list(includeOffscreen: Bool = false) -> [WindowInfo] {
        let opts: CGWindowListOption = includeOffscreen
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        var regular: [pid_t: Bool] = [:]
        func isRegularApp(_ pid: pid_t) -> Bool {
            if let r = regular[pid] { return r }
            let r = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            regular[pid] = r
            return r
        }
        let windows = raw.compactMap { d -> WindowInfo? in
            guard let w = parse(d), w.pid != me else { return nil }
            if w.onScreen { return w }
            // Hors écran, beaucoup de fenêtres techniques existent : on ne garde que les vraies.
            let alpha = d[kCGWindowAlpha as String] as? Double ?? 0
            return !w.title.isEmpty && alpha > 0 && isRegularApp(w.pid) ? w : nil
        }
        return windows.filter(\.onScreen) + windows.filter { !$0.onScreen }
    }

    static func info(for id: CGWindowID) -> WindowInfo? {
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = raw.first else { return nil }
        return parse(d)
    }

    private static func parse(_ d: [String: Any]) -> WindowInfo? {
        guard (d[kCGWindowLayer as String] as? Int) == 0,
              let id = d[kCGWindowNumber as String] as? CGWindowID,
              let pid = d[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = d[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              frame.width > 60, frame.height > 60 else { return nil }
        return WindowInfo(id: id, pid: pid,
                          appName: d[kCGWindowOwnerName as String] as? String ?? "?",
                          title: d[kCGWindowName as String] as? String ?? "",
                          frame: frame,
                          onScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    /// Fenêtre qui a le focus clavier dans l'app `pid` (nécessite l'autorisation Accessibilité).
    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(value as! AXUIElement, &id) == .success ? id : nil
    }

    static func axWindow(for info: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(info.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(w, &wid) == .success && wid == info.id
        }
    }

    static func bringToFront(_ info: WindowInfo) {
        if let w = axWindow(for: info) {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        NSRunningApplication(processIdentifier: info.pid)?.activate()
    }

    static func move(_ info: WindowInfo, toTopLeft point: CGPoint) {
        guard let w = axWindow(for: info) else { return }
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
        }
    }

    // Conversion entre coordonnées CoreGraphics (haut-gauche) et Cocoa (bas-gauche).
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoaRect(_ cg: CGRect) -> NSRect {
        NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    static func cgTopLeft(of cocoa: NSRect) -> CGPoint {
        CGPoint(x: cocoa.minX, y: primaryHeight - cocoa.maxY)
    }
}
