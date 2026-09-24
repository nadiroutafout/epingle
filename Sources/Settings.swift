import Cocoa
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Modificateurs Carbon (controlKey, optionKey…).
    var modifiers: UInt32
    /// Nom affiché de la touche : « P », « Espace »…
    var key: String

    static let defaultPin = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), key: "P")
    static let defaultSearch = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), key: "Espace")

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Nil si aucun des modificateurs ⌃, ⌥ ou ⌘ n'est utilisé.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        guard m & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, key: Shortcut.keyName(event))
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// Pour afficher le raccourci à droite d'un élément de menu.
    var menuKeyEquivalent: String {
        switch key {
        case "Espace": return " "
        case "↩": return "\r"
        default: return key.count == 1 ? key.lowercased() : ""
        }
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Espace", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ e: NSEvent) -> String {
        specialKeys[Int(e.keyCode)] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

enum Settings {
    static let changed = Notification.Name("EpingleSettingsChanged")
    private static var defaults: UserDefaults { .standard }

    static var pinShortcut: Shortcut {
        get { load("pinShortcut") ?? .defaultPin }
        set { store(newValue, "pinShortcut") }
    }

    static var searchShortcut: Shortcut {
        get { load("searchShortcut") ?? .defaultSearch }
        set { store(newValue, "searchShortcut") }
    }

    /// Images par seconde des copies épinglées.
    static var frameRate: Int {
        get { let v = defaults.integer(forKey: "frameRate"); return v > 0 ? v : 30 }
        set { defaults.set(newValue, forKey: "frameRate"); notify() }
    }

    static var showBadge: Bool {
        get { defaults.object(forKey: "showBadge") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showBadge"); notify() }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
        notify()
    }

    private static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Ce qu'il faut pour réépingler une fenêtre après une relance.
struct PinEntry: Codable {
    var bundleID: String
    var appName: String
    var title: String
    /// Zone gardée, en points, origine en haut à gauche de la fenêtre.
    var crop: CGRect?
    /// Cadre du panneau (Cocoa) s'il a été redimensionné ou recadré.
    var frame: CGRect?
    var opacity: Double
    var ghost: Bool

    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

enum PinStore {
    private static let key = "pins"

    static func load() -> [PinEntry] {
        UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([PinEntry].self, from: $0) } ?? []
    }

    static func save(_ entries: [PinEntry]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}
