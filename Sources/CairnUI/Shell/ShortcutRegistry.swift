import AppKit
import CairnCore
import CairnModules

/// A machine-readable key combination. `key` is a lowercase character or one of the named keys below.
public struct KeyChord: Codable, Hashable, Sendable {
    public var key: String
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    static let namedKeys: [String: (symbol: String, equivalent: String)] = [
        "tab": ("⇥", "\t"), "return": ("↩", "\r"), "escape": ("⎋", "\u{1B}"), "space": ("Space", " "),
        "delete": ("⌫", "\u{8}"),
        "up": ("↑", String(UnicodeScalar(NSUpArrowFunctionKey)!)), "down": ("↓", String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "left": ("←", String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "right": ("→", String(UnicodeScalar(NSRightArrowFunctionKey)!)),
    ]

    /// Parses display text such as "⇧⌘D", "⌃⇧+" or "⌘⌥↓". Returns nil for text that is not a shortcut.
    public static func parse(_ text: String) -> KeyChord? {
        var chord = KeyChord("")
        var rest = ""
        for character in text where !character.isWhitespace {
            switch character {
            case "⌘": chord.command = true
            case "⇧": chord.shift = true
            case "⌥": chord.option = true
            case "⌃": chord.control = true
            default: rest.append(character)
            }
        }
        let normalized = rest == "−" ? "-" : rest
        if let named = namedKeys.first(where: { $0.value.symbol == normalized }) { chord.key = named.key }
        else if normalized.count == 1 { chord.key = normalized.lowercased() }
        else { return nil }
        return chord.command || chord.control || chord.option ? chord : nil
    }

    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (Self.namedKeys[key]?.symbol ?? key.uppercased())
    }

    public var keyEquivalent: String { Self.namedKeys[key]?.equivalent ?? key }

    public var modifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    public init?(event: NSEvent) {
        guard event.type == .keyDown, let raw = event.charactersIgnoringModifiers?.lowercased(), !raw.isEmpty else { return nil }
        var key: String
        switch event.keyCode {
        case 48: key = "tab"
        case 36, 76: key = "return"
        case 53: key = "escape"
        case 49: key = "space"
        case 51: key = "delete"
        case 126: key = "up"
        case 125: key = "down"
        case 123: key = "left"
        case 124: key = "right"
        default:
            guard raw.count == 1 else { return nil }
            key = raw
        }
        if key == "=" && event.modifierFlags.contains(.shift) { key = "+" }
        let flags = event.modifierFlags
        self.init(key, command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }
}

public enum ShortcutMenu: String, CaseIterable, Sendable {
    case file = "File", edit = "Edit", view = "View", history = "History", tabs = "Tabs", spaces = "Spaces",
         split = "Split View", tools = "Tools"
}

public enum KeymapPreset: String, Codable, CaseIterable, Sendable {
    case cairn, arc
    public var title: String { self == .cairn ? "Cairn" : "Arc-compatible" }
}

/// A command with a menu home and a default chord per preset. IDs are the same ones the command bar uses.
public struct ShortcutAction: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var menu: ShortcutMenu
    public var cairn: KeyChord?
    public var arc: KeyChord?
    /// Fixed system bindings (Quit, Copy…) take part in conflict checks but cannot be remapped.
    public var remappable = true
    public var symbol: String?

    public init(_ id: String, _ title: String, _ menu: ShortcutMenu, cairn: KeyChord? = nil, arc: KeyChord?? = nil,
                remappable: Bool = true, symbol: String? = nil) {
        self.id = id; self.title = title; self.menu = menu; self.cairn = cairn
        self.arc = arc ?? cairn
        self.remappable = remappable; self.symbol = symbol
    }

    public func chord(in preset: KeymapPreset) -> KeyChord? { preset == .cairn ? cairn : arc }
}

public struct ShortcutError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Pure resolution of presets and user remaps. Persistence lives in `ShortcutStore`.
public struct ShortcutMap: Equatable, Sendable {
    public private(set) var actions: [ShortcutAction]
    public var preset: KeymapPreset
    public private(set) var assigned: [String: KeyChord]
    public private(set) var cleared: Set<String>

    public init(actions: [ShortcutAction] = ShortcutCatalog.actions, preset: KeymapPreset = .cairn,
                assigned: [String: KeyChord] = [:], cleared: Set<String> = []) {
        self.actions = actions
        self.preset = preset
        let known = Set(actions.filter(\.remappable).map(\.id))
        self.assigned = assigned.filter { known.contains($0.key) }
        self.cleared = cleared.intersection(known).subtracting(self.assigned.keys)
    }

    public func action(_ id: String) -> ShortcutAction? { actions.first { $0.id == id } }

    public func chord(for id: String) -> KeyChord? {
        guard let action = action(id) else { return nil }
        if let custom = assigned[id] { return custom }
        if cleared.contains(id) { return nil }
        return action.chord(in: preset)
    }

    public var bindings: [String: KeyChord] {
        Dictionary(uniqueKeysWithValues: actions.compactMap { action in chord(for: action.id).map { (action.id, $0) } })
    }

    public func owner(of chord: KeyChord, excluding id: String? = nil) -> ShortcutAction? {
        actions.first { $0.id != id && self.chord(for: $0.id) == chord }
    }

    public mutating func assign(_ chord: KeyChord?, to id: String) throws {
        guard let action = action(id), action.remappable else { throw ShortcutError(message: "This shortcut is fixed and cannot be changed.") }
        if let chord {
            guard chord.command || chord.control || chord.option else {
                throw ShortcutError(message: "Use at least one of ⌘, ⌃ or ⌥ so typing is not affected.")
            }
            if let other = owner(of: chord, excluding: id) {
                throw ShortcutError(message: "\(chord.display) is already used by “\(other.title)”. Change or clear that shortcut first.")
            }
            assigned[id] = chord
            cleared.remove(id)
        } else {
            assigned[id] = nil
            cleared.insert(id)
        }
    }

    public mutating func reset(_ id: String) { assigned[id] = nil; cleared.remove(id) }
    public mutating func resetAll() { assigned = [:]; cleared = [] }

    /// Adds actions discovered from registered commands (modules, other features) that declare a shortcut string.
    /// A discovered binding that collides with a known one is left unbound instead of stealing it.
    public func adding(discovered commands: [Command]) -> ShortcutMap {
        var copy = self
        let titles = Set(actions.map { $0.title.lowercased() })
        for command in commands where action(command.id) == nil && !titles.contains(command.title.lowercased()) {
            guard let chord = command.shortcut.flatMap(KeyChord.parse), copy.owner(of: chord) == nil else { continue }
            copy.actions.append(ShortcutAction(command.id, command.title, .tools, cairn: chord, symbol: command.symbol))
        }
        return copy
    }
}

public enum ShortcutCatalog {
    private static func chord(_ key: String, _ flags: String) -> KeyChord {
        KeyChord(key, command: flags.contains("c"), shift: flags.contains("s"), option: flags.contains("o"), control: flags.contains("k"))
    }

    /// Every Arc shortcut row that has no Cairn feature; shown in docs and the shortcuts pane.
    public static let unmappedArcRows = [
        "⌘N New window", "⇧⌘N Incognito window", "⌘⌥N Little Arc window", "⌘← / ⌘→ History (conflicts with text editing; use ⌘[ and ⌘])",
    ]

    public static let actions: [ShortcutAction] = {
        var list: [ShortcutAction] = [
            .init("ui.new-tab", "New Tab", .file, cairn: chord("t", "c"), symbol: "plus"),
            .init("ui.command-bar", "Command Bar…", .file, cairn: chord("k", "c"), symbol: "command"),
            .init("ui.address", "Open Location…", .file, cairn: chord("l", "c"), symbol: "link"),
            .init("ui.close-tab", "Close Tab", .file, cairn: chord("w", "c"), symbol: "xmark"),
            .init("ui.close-window", "Close Window", .file, cairn: chord("w", "cs")),
            .init("ui.reopen-closed-tab", "Reopen Closed Tab", .file, cairn: chord("t", "cs"), symbol: "arrow.uturn.backward"),
            .init("ui.print", "Print…", .file, cairn: chord("p", "c"), symbol: "printer"),
            .init("ui.save-pdf", "Save Page as PDF…", .file, symbol: "doc.richtext"),
            .init("ui.copy-url", "Copy Page Address", .edit, cairn: chord("c", "cs"), symbol: "link"),
            .init("ui.copy-markdown-link", "Copy Page Link as Markdown", .edit, cairn: chord("c", "cso")),
            .init("ui.find", "Find in Page…", .edit, cairn: chord("f", "c"), symbol: "magnifyingglass"),
            .init("ui.find-next", "Find Next", .edit, cairn: chord("g", "c")),
            .init("ui.find-previous", "Find Previous", .edit, cairn: chord("g", "cs")),
            .init("ui.sidebar", "Toggle Sidebar", .view, cairn: chord("s", "cs"), arc: chord("s", "c"), symbol: "sidebar.left"),
            .init("ui.reload", "Reload Page", .view, cairn: chord("r", "c"), symbol: "arrow.clockwise"),
            .init("ui.hard-reload", "Reload Without Cache", .view, cairn: chord("r", "cs")),
            .init("ui.stop", "Stop Loading", .view, cairn: chord(".", "c")),
            .init("ui.zoom-in", "Zoom In", .view, cairn: chord("+", "c"), symbol: "plus.magnifyingglass"),
            .init("ui.zoom-out", "Zoom Out", .view, cairn: chord("-", "c"), symbol: "minus.magnifyingglass"),
            .init("ui.zoom-reset", "Actual Size", .view, cairn: chord("0", "c"), symbol: "1.magnifyingglass"),
            .init("ui.reset-site-zoom", "Reset Zoom for All Sites", .view, symbol: "1.magnifyingglass"),
            .init("ui.back", "Back", .history, cairn: chord("[", "c")),
            .init("ui.forward", "Forward", .history, cairn: chord("]", "c")),
            .init("ui.history", "Show History", .history, cairn: chord("y", "c"), symbol: "clock"),
            .init("ui.archive", "Archived Tabs", .history, symbol: "archivebox"),
            .init("ui.pin-tab", "Pin or Unpin Tab", .tabs, cairn: nil, arc: chord("d", "c"), symbol: "pin"),
            .init("ui.clear-today", "Clear Today", .tabs, cairn: nil, arc: chord("k", "cs"), symbol: "trash"),
            .init("ui.next-tab", "Next Tab", .tabs, cairn: chord("down", "co")),
            .init("ui.previous-tab", "Previous Tab", .tabs, cairn: chord("up", "co")),
            .init("ui.recent-tabs", "Switch to Recent Tab", .tabs, cairn: chord("tab", "k")),
            .init("ui.recent-tabs-previous", "Switch to Older Recent Tab", .tabs, cairn: chord("tab", "ks")),
            .init("ui.next-space", "Next Space", .spaces, cairn: chord("right", "co")),
            .init("ui.previous-space", "Previous Space", .spaces, cairn: chord("left", "co")),
            .init("ui.split", "Toggle Split View", .split, cairn: chord("d", "cs"), symbol: "rectangle.split.2x1"),
            .init("ui.split-add-right", "Add Right Split", .split, cairn: nil, arc: chord("+", "ks")),
            .init("ui.split-add-left", "Add Left Split", .split),
            .init("ui.split-add-top", "Add Top Split", .split),
            .init("ui.split-add-bottom", "Add Bottom Split", .split),
            .init("ui.split-remove-pane", "Remove Pane from Split", .split, cairn: nil, arc: chord("-", "ks")),
            .init("ui.split-separate", "Separate All Tabs", .split),
            .init("ui.downloads", "Downloads", .tools, cairn: chord("j", "c"), symbol: "arrow.down.circle"),
            .init("ui.devtools", "Toggle Developer Tools", .tools, cairn: chord("i", "co"), symbol: "hammer"),
            .init("ui.view-source", "View Page Source", .tools, cairn: chord("u", "co"), symbol: "chevron.left.forwardslash.chevron.right"),
            .init("ui.boosts", "Boosts", .tools, symbol: "paintbrush"),
            .init("ui.shortcuts", "Keyboard Shortcuts…", .tools, symbol: "keyboard"),
            .init("ui.settings", "Settings…", .tools, cairn: chord(",", "c"), symbol: "gearshape"),
            // Fixed system bindings reserve their keys so no remap can shadow them.
            .init("system.quit", "Quit Cairn", .tools, cairn: chord("q", "c"), remappable: false),
            .init("system.hide", "Hide Cairn", .tools, cairn: chord("h", "c"), remappable: false),
            .init("system.hide-others", "Hide Others", .tools, cairn: chord("h", "co"), remappable: false),
            .init("system.minimize", "Minimize", .tools, cairn: chord("m", "c"), remappable: false),
            .init("system.undo", "Undo", .edit, cairn: chord("z", "c"), remappable: false),
            .init("system.redo", "Redo", .edit, cairn: chord("z", "cs"), remappable: false),
            .init("system.cut", "Cut", .edit, cairn: chord("x", "c"), remappable: false),
            .init("system.copy", "Copy", .edit, cairn: chord("c", "c"), remappable: false),
            .init("system.paste", "Paste", .edit, cairn: chord("v", "c"), remappable: false),
            .init("system.select-all", "Select All", .edit, cairn: chord("a", "c"), remappable: false),
        ]
        for number in 1...9 {
            list.append(.init("ui.select-tab-\(number)", "Tab \(number)", .tabs, cairn: chord("\(number)", "c")))
            list.append(.init("ui.select-space-\(number)", "Space \(number)", .spaces, cairn: chord("\(number)", "k")))
        }
        for number in 1...SplitLayout.maximumPanes {
            list.append(.init("ui.split-focus-\(number)", "Focus Pane \(number)", .split, cairn: nil, arc: chord("\(number)", "ks")))
        }
        return list
    }()
}
