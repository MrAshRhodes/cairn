import Foundation
import CairnCore
import CairnEngineKit

@MainActor
final class BrowserCommandsModule: CairnModule {
    let id = "cairn.browser"
    let displayName = "Browser"
    let version = "1"

    func commands(for model: BrowserModel) -> [Command] {
        var commands = [
            Command(id: "cairn.tab.new", title: "New Tab", symbol: "plus", keywords: ["open"], shortcut: "⌘T") { $0.newTab() },
            Command(id: "cairn.space.new", title: "New Space", symbol: "square.grid.2x2", keywords: ["workspace"]) {
                $0.addSpace(name: "New Space")
            },
        ]
        if !model.splitTabIDs.isEmpty {
            commands.append(Command(id: "cairn.split.close", title: "Close Split View", symbol: "rectangle") { $0.closeSplit() })
        }
        if let selected = model.selectedTab, let location = model.locate(selected.id) {
            commands += [
                Command(id: "cairn.tab.close", title: "Close Tab", symbol: "xmark", shortcut: "⌘W") {
                    if let id = $0.selectedTabID { $0.closeTab(id) }
                },
                Command(id: "cairn.tab.duplicate", title: "Duplicate Tab", symbol: "plus.square.on.square") {
                    if let tab = $0.selectedTab { $0.newTab(url: tab.url) }
                },
                Command(id: "cairn.tab.pin", title: location.list == .pinned ? "Unpin Tab" : "Pin Tab", symbol: "pin") {
                    guard let id = $0.selectedTabID else { return }
                    if $0.locate(id)?.list == .pinned { $0.unpin(id) } else { $0.pin(id) }
                },
                Command(id: "cairn.tab.favorite", title: location.list == .favorites ? "Remove Favorite" : "Favorite Tab", symbol: "star") {
                    guard let id = $0.selectedTabID else { return }
                    if $0.locate(id)?.list == .favorites { $0.unfavorite(id) } else { $0.favorite(id) }
                },
                Command(id: "cairn.split.open", title: "Split View", symbol: "rectangle.split.2x1", keywords: ["side by side"]) {
                    guard let id = $0.selectedTabID else { return }
                    let visible = $0.workspace.favorites + $0.selectedSpace.pinned + $0.selectedSpace.tabs
                    let other = visible.first { $0.id != id }?.id ?? $0.newTab(activate: false)
                    $0.splitSelected(with: other)
                },
                engineCommand("cairn.navigation.reload", "Reload Page", "arrow.clockwise", shortcut: "⌘R") { $0.reload(ignoringCache: false) },
                engineCommand("cairn.navigation.reloadWithoutCache", "Reload Without Cache", "arrow.clockwise", shortcut: "⇧⌘R") { $0.reload(ignoringCache: true) },
                engineCommand("cairn.navigation.stop", "Stop Loading", "xmark.circle") { $0.stopLoading() },
                engineCommand("cairn.navigation.back", "Go Back", "chevron.left", shortcut: "⌘[") { $0.goBack() },
                engineCommand("cairn.navigation.forward", "Go Forward", "chevron.right", shortcut: "⌘]") { $0.goForward() },
                engineCommand("cairn.zoom.in", "Zoom In", "plus.magnifyingglass", shortcut: "⌘+") { $0.zoom = min(3, max(0.25, $0.zoom + 0.1)) },
                engineCommand("cairn.zoom.out", "Zoom Out", "minus.magnifyingglass", shortcut: "⌘−") { $0.zoom = min(3, max(0.25, $0.zoom - 0.1)) },
                engineCommand("cairn.zoom.reset", "Actual Size", "1.magnifyingglass", shortcut: "⌘0") { $0.zoom = 1 },
            ]
            if selected.homeURL != nil {
                commands.append(Command(id: "cairn.tab.reset", title: "Reset to Pinned URL", symbol: "house") {
                    if let tab = $0.selectedTab, let home = tab.homeURL { $0.load(home, in: tab.id) }
                })
            }
            if location.list == .today {
                commands.append(Command(id: "cairn.tab.archive", title: "Archive Tab", symbol: "archivebox") {
                    guard let id = $0.selectedTabID, $0.locate(id)?.list == .today else { return }
                    let next = ($0.selectedSpace.tabs + $0.selectedSpace.pinned + $0.workspace.favorites).first { $0.id != id }?.id
                    $0.unloadTab(id)
                    $0.moveTab(id, to: .archive)
                    if let next { $0.select(next) } else { $0.newTab() }
                })
            }
            let visible = model.workspace.favorites + model.selectedSpace.pinned + model.selectedSpace.tabs
            if visible.count > 1 {
                commands += [
                    cycleCommand("cairn.tab.next", "Next Tab", offset: 1),
                    cycleCommand("cairn.tab.previous", "Previous Tab", offset: -1),
                ]
            }
        }
        for tab in model.selectedSpace.archive {
            commands.append(Command(id: "cairn.archive.restore.\(tab.id.uuidString)", title: "Restore \(tab.displayTitle)", symbol: "arrow.uturn.backward",
                                    keywords: ["archive"]) { model in
                guard model.locate(tab.id)?.list == .archive else { return }
                model.moveTab(tab.id, to: .today)
                model.select(tab.id)
            })
        }
        for space in model.workspace.spaces where space.id != model.selectedSpace.id {
            commands.append(Command(id: "cairn.space.select.\(space.id.uuidString)", title: "Switch to \(space.name)", symbol: "square.grid.2x2") {
                $0.selectSpace(space.id)
            })
        }
        return commands
    }

    private func engineCommand(_ id: String, _ title: String, _ symbol: String, shortcut: String? = nil,
                               action: @escaping @MainActor @Sendable (EngineTab) -> Void) -> Command {
        Command(id: id, title: title, symbol: symbol, shortcut: shortcut) { model in
            if let id = model.selectedTabID, let tab = model.liveTab(for: id) { action(tab) }
        }
    }

    private func cycleCommand(_ id: String, _ title: String, offset: Int) -> Command {
        Command(id: id, title: title, symbol: "arrow.right.arrow.left") { model in
            let tabs = model.workspace.favorites + model.selectedSpace.pinned + model.selectedSpace.tabs
            guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == model.selectedTabID }) else { return }
            model.select(tabs[(index + offset + tabs.count) % tabs.count].id)
        }
    }
}
