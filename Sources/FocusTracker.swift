import Cocoa
import ApplicationServices

/// Suit l'app active et la fenêtre qui a le focus en son sein (changement d'app, ou de fenêtre dans la même app).
@MainActor
final class FocusTracker {
    var onChange: ((pid_t, CGWindowID?) -> Void)?
    private var observer: AXObserver?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            MainActor.assumeIsolated {
                self?.observe(pid: pid)
                self?.report()
            }
        }
        observe(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }

    /// App active et fenêtre qui a le focus (nil si inconnue).
    func current() -> (pid: pid_t, window: CGWindowID?) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        return (pid, pid == getpid() ? nil : Windows.focusedWindowID(pid: pid))
    }

    fileprivate func report() {
        let c = current()
        onChange?(c.pid, c.window)
    }

    private func observe(pid: pid_t) {
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
            observer = nil
        }
        guard pid > 0, pid != getpid() else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.report() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(created, app, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }
}
