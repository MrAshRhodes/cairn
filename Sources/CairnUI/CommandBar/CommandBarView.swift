import SwiftUI
import CairnCore
import CairnModules

public enum CommandBarAction: Equatable, Sendable {
    case moveToSpace(UUID), pinToSpace(UUID)
}

public struct CommandBarMatch: Identifiable {
    public enum Target {
        case tab(UUID), command(String), navigation(String), history(URL)
        case siteSearch(SiteSearchEngine, String), beginSiteSearch(SiteSearchEngine), action(CommandBarAction)
    }
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let shortcut: String?
    public let target: Target
}

/// Result construction without history or site search; kept for callers that only know tabs and commands.
public enum CommandBarSearch {
    public static func matches(query: String, workspace: Workspace, commands: [Command]) -> [CommandBarMatch] {
        CommandBarRanking.rank(query: query, context: CommandBarContext(workspace: workspace, commands: commands))
    }

    public static func nextSelection(_ index: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index + delta % count + count) % count
    }
}

@MainActor
public struct CommandBarView: View {
    let dismiss: () -> Void
    @ViewState<CommandBarModel> private var bar: CommandBarModel
    @FocusState private var focused: Bool

    public init(model: BrowserModel, commands: @escaping () -> [Command], mode: CommandBarMode = .search,
                history: HistoryStore? = nil, engines: @escaping () -> [SiteSearchEngine] = { [] },
                report: @escaping (String, String) -> Void = { _, _ in }, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        _bar = ViewState(initialValue: CommandBarModel(mode: mode, browser: model, history: history, commands: commands(),
                                                        engines: engines, report: report))
    }

    private var matches: [CommandBarMatch] { bar.matches }

    public var body: some View {
        @Bindable var bar = bar
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                if let engine = bar.activeEngine {
                    Text(engine.name).font(.callout.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .accessibilityLabel("Searching \(engine.name). Press delete to remove.")
                }
                TextField(bar.placeholder, text: $bar.query)
                    .font(.system(size: 18)).textFieldStyle(.plain).focused($focused)
                    .onSubmit { activateSelected() }
                    .onMoveCommand { direction in
                        if direction == .down { bar.moveSelection(1) }
                        if direction == .up { bar.moveSelection(-1) }
                    }
                    .onKeyPress(.tab) { bar.handleTab() ? .handled : .ignored }
                    .onKeyPress(.delete) { bar.handleDeleteOnEmpty() ? .handled : .ignored }
                    .onExitCommand { dismiss() }
                    .accessibilityLabel(bar.placeholder)
                    .accessibilityValue(matches.isEmpty ? "No results" : "\(matches.count) results")
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
                                    .background(index == bar.selection ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).id(index)
                                .accessibilityLabel("\(match.title), \(match.subtitle)")
                                .accessibilityAddTraits(index == bar.selection ? .isSelected : [])
                        }
                        if matches.isEmpty {
                            Text(bar.activeEngine == nil ? "No matches. Try another word." : "Type what to search for.")
                                .foregroundStyle(.secondary).padding(28)
                        }
                    }.padding(9)
                }.frame(maxHeight: 370)
                    .onChange(of: bar.selection) { _, value in proxy.scrollTo(value) }
            }
            Divider()
            HStack {
                Text("↑↓ select   ↵ open   ⇥ site search   esc dismiss")
                Spacer()
                Text("Type > for commands")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(13)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
        .onAppear {
            focused = true
            if bar.startsSelected {
                DispatchQueue.main.async {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor { editor.selectAll(nil) }
                }
            }
        }
    }

    private func activateSelected() {
        guard matches.indices.contains(bar.selection) else { return }
        activate(matches[bar.selection])
    }

    private func activate(_ match: CommandBarMatch) {
        if case .beginSiteSearch = match.target { bar.activate(match); return }
        dismiss()
        bar.activate(match)
    }
}
