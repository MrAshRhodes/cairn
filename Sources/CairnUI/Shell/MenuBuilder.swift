import AppKit

/// Builds the registry-driven menus. Items carry the action id in `representedObject`, so the keymap, menus,
/// the command bar and the shortcuts pane all share one source of truth.
@MainActor
public enum MenuBuilder {
    // Settings lives in the app menu, so the menus built here skip `ui.settings`.
    private static let groups: [(prefix: String, title: String, menu: ShortcutMenu)] = [
        ("ui.select-tab-", "Select Tab", .tabs),
        ("ui.select-space-", "Select Space", .spaces),
        ("ui.split-focus-", "Focus Pane", .split),
    ]

    public static func menu(_ kind: ShortcutMenu, map: ShortcutMap, target: AnyObject, action: Selector) -> NSMenu {
        let result = NSMenu(title: kind.rawValue)
        var submenus: [String: NSMenu] = [:]
        for entry in map.actions where entry.menu == kind && !entry.id.hasPrefix("system.") && entry.id != "ui.settings" {
            if let group = groups.first(where: { entry.id.hasPrefix($0.prefix) }) {
                if submenus[group.prefix] == nil {
                    let holder = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                    let sub = NSMenu(title: group.title)
                    holder.submenu = sub
                    result.addItem(holder)
                    submenus[group.prefix] = sub
                }
                submenus[group.prefix]?.addItem(item(entry, map: map, target: target, action: action))
            } else {
                result.addItem(item(entry, map: map, target: target, action: action))
            }
        }
        return result
    }

    public static func item(_ entry: ShortcutAction, map: ShortcutMap, target: AnyObject, action: Selector) -> NSMenuItem {
        let chord = map.chord(for: entry.id)
        let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: chord?.keyEquivalent ?? "")
        item.keyEquivalentModifierMask = chord?.modifierMask ?? []
        item.representedObject = entry.id
        item.target = target
        return item
    }
}
