import SwiftUI
import CairnCore
import CairnModules

public struct CommandBarMatch: Identifiable {
    public enum Target { case tab(UUID), command(String), navigation(String) }
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let shortcut: String?
    public let target: Target
}

/// Pure result construction keeps keyboard selection independent of SwiftUI's focus machinery.
public enum CommandBarSearch {
    public static func matches(query: String, workspace: Workspace, commands: [Command]) -> [CommandBarMatch] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandOnly = text.hasPrefix(">")
        let needle = commandOnly ? String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : text
        func contains(_ values: [String]) -> Bool {
            needle.isEmpty || needle.split(separator: " ").allSatisfy { word in
                values.contains { $0.localizedCaseInsensitiveContains(String(word)) }
            }
        }
        var results: [CommandBarMatch] = []
        if !commandOnly {
            let groups: [(String, [TabItem])] = [("Favorites", workspace.favorites)] +
                workspace.spaces.map { ($0.name, $0.pinned + $0.tabs) }
            for (group, tabs) in groups {
                for tab in tabs where contains([tab.displayTitle, tab.title, tab.url?.absoluteString ?? "", group]) {
                    results.append(.init(id: "tab:\(tab.id)", title: tab.displayTitle, subtitle: group + " · " + (tab.url?.host ?? "New Tab"),
                                         symbol: "rectangle.on.rectangle", shortcut: nil, target: .tab(tab.id)))
                }
            }
        }
        for command in commands where contains([command.title, command.subtitle ?? ""] + command.keywords) {
            results.append(.init(id: "command:\(command.id)", title: command.title, subtitle: command.subtitle ?? "Command",
                                 symbol: command.symbol ?? "command", shortcut: command.shortcut, target: .command(command.id)))
        }
        if !text.isEmpty && !commandOnly {
            results = Array(results.prefix(59))
            results.append(.init(id: "navigate", title: "Go to “\(text)”", subtitle: "Open a website or search in a new tab",
                                 symbol: "arrow.up.right", shortcut: "↵", target: .navigation(text)))
        }
        return Array(results.prefix(60))
    }

    public static func nextSelection(_ index: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index + delta % count + count) % count
    }
}

@MainActor
public struct CommandBarView: View {
    let model: BrowserModel
    let commands: () -> [Command]
    let dismiss: () -> Void
    @ViewState<String> private var query = ""
    @ViewState<Int> private var selection = 0
    @ViewState<[Command]> private var availableCommands = []
    @FocusState private var focused: Bool

    public init(model: BrowserModel, commands: @escaping () -> [Command], dismiss: @escaping () -> Void) {
        self.model = model
        self.commands = commands
        self.dismiss = dismiss
    }
    private var matches: [CommandBarMatch] {
        CommandBarSearch.matches(query: query, workspace: model.workspace, commands: availableCommands)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tabs, commands, or the web", text: $query)
                    .font(.system(size: 18)).textFieldStyle(.plain).focused($focused)
                    .onSubmit { activateSelected() }
                    .onMoveCommand { direction in
                        if direction == .down { selection = CommandBarSearch.nextSelection(selection, delta: 1, count: matches.count) }
                        if direction == .up { selection = CommandBarSearch.nextSelection(selection, delta: -1, count: matches.count) }
                    }
                    .onExitCommand { dismiss() }
                    .accessibilityLabel("Search tabs, commands, or the web")
                Button("esc", action: dismiss).buttonStyle(.plain).font(.caption.monospaced())
                    .foregroundStyle(.secondary).help("Close command bar")
            }.padding(22)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            Button { activate(match) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: match.symbol).font(.system(size: 15)).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(match.title).lineLimit(1).font(.callout.weight(.medium))
                                        Text(match.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let shortcut = match.shortcut { Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .background(index == selection ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).id(index)
                                .accessibilityAddTraits(index == selection ? .isSelected : [])
                        }
                        if matches.isEmpty {
                            Text("No matches. Try another word.").foregroundStyle(.secondary).padding(28)
                        }
                    }.padding(9)
                }.frame(maxHeight: 370)
                    .onChange(of: selection) { _, value in proxy.scrollTo(value) }
            }
            Divider()
            HStack {
                Text("↑↓ select   ↵ open   esc dismiss")
                Spacer()
                Text("Type > for commands")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(13)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
        .onAppear { availableCommands = commands(); focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func activateSelected() {
        guard matches.indices.contains(selection) else { return }
        activate(matches[selection])
    }
    private func activate(_ match: CommandBarMatch) {
        dismiss()
        switch match.target {
        case .tab(let id): model.select(id)
        case .command(let id): availableCommands.first { $0.id == id }?.perform(model)
        case .navigation(let query):
            guard let url = URLResolver.resolve(query, searchTemplate: model.searchTemplate) else { return }
            model.newTab(url: url)
        }
    }
}
