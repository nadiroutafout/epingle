import Cocoa
import Carbon.HIToolbox

/// Raccourcis clavier globaux (API Carbon : aucune autorisation requise).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var specs: [UInt32: (shortcut: Shortcut, handler: () -> Void)] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var suspended = false

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) { specs[id]?.handler() }

    func register(id: UInt32, _ shortcut: Shortcut, handler: @escaping () -> Void) {
        specs[id] = (shortcut, handler)
        if !suspended { activate(id) }
    }

    /// Pendant l'enregistrement d'un nouveau raccourci, pour que les touches arrivent à la fenêtre de réglages.
    func suspend() {
        suspended = true
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    func resume() {
        suspended = false
        specs.keys.forEach { activate($0) }
    }

    private func activate(_ id: UInt32) {
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        guard let spec = specs[id] else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4550_494E), id: id) // 'EPIN'
        if RegisterEventHotKey(spec.shortcut.keyCode, spec.shortcut.modifiers, hotKeyID,
                               GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[id] = ref
        }
    }
}
