import SwiftUI
import CairnCore
import CairnModules

@MainActor
public struct SidebarView: View {
    let model: BrowserModel
    let showCommandBar: () -> Void
    let services: BrowserServices?
    @ViewState<Space?> private var editedSpace = nil
    @ViewState<Bool> private var creatingSpace = false
    @ViewState<Space?> private var deletingSpace = nil
    @ViewState<Bool> private var archivePresented = false
    @ViewState<TabItem?> private var renamingTab = nil
    @ViewState<String> private var tabTitle = ""

    public init(model: BrowserModel, showCommandBar: @escaping () -> Void, services: BrowserServices? = nil) {
        self.model = model
        self.showCommandBar = showCommandBar
        self.services = services
    }

    private var accent: Color { Color(cairnHex: model.selectedSpace.colorHex) }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                SymbolButton(title: "Hide Sidebar", symbol: "sidebar.left") { services?.sidebarVisible = false }
            }.frame(height: 36).padding(.horizontal, 10)
            HStack(spacing: 10) {
                Image(systemName: "mountain.2").font(.system(size: 20, weight: .light)).foregroundStyle(accent)
                Text("cairn").font(.system(size: 24, weight: .medium, design: .serif))
                Spacer()
                Menu {
                    Button("New Space…") { creatingSpace = true }
                    Button("Edit Space…") { editedSpace = model.selectedSpace }
                    Button("Delete Space…", role: .destructive) { deletingSpace = model.selectedSpace }
                        .disabled(model.workspace.spaces.count < 2)
                    Divider()
                    Button("Settings…") { services?.sheet = .preferences }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 32) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Space and browser settings")
            }.padding(.horizontal, 18).padding(.bottom, 18)
            Button(action: showCommandBar) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Find anything")
                    Spacer()
                    Text("⌘K").font(.caption)
                }.foregroundStyle(.secondary).padding(11)
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 14)
                .accessibilityLabel("Search tabs and commands")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.workspace.favorites.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            heading("FAVORITES", symbol: "star")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                                ForEach(model.workspace.favorites) { tab in
                                    Button { select(tab.id) } label: {
                                        VStack(spacing: 5) {
                                            tabIcon(tab).font(.system(size: 18))
                                            Text(tab.displayTitle).font(.system(size: 10)).lineLimit(1)
                                        }.frame(maxWidth: .infinity).frame(height: 56)
                                            .background(tab.id == model.selectedTabID ? accent.opacity(0.20) : Color.primary.opacity(0.05),
                                                        in: RoundedRectangle(cornerRadius: 11))
                                    }.buttonStyle(.plain).help(tab.displayTitle).accessibilityLabel("Favorite: \(tab.displayTitle)")
                                        .accessibilityAddTraits(tab.id == model.selectedTabID ? .isSelected : [])
                                        .contextMenu { tabMenu(tab, list: .favorites) }
                                        .draggable(tab.id.uuidString)
                                        .dropDestination(for: String.self) { items, _ in move(items, to: .favorites, before: tab.id) }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            spaceIcon(model.selectedSpace).foregroundStyle(accent)
                            Text(model.selectedSpace.name).font(.headline).lineLimit(1)
                            Spacer()
                            Image(systemName: "lock.shield").font(.caption).foregroundStyle(.tertiary)
                                .help("This Space has its own cookies and site storage")
                        }
                        .padding(.horizontal, 7)
                        .contextMenu {
                            Button("Edit Space…") { editedSpace = model.selectedSpace }
                            Button("Delete Space…", role: .destructive) { deletingSpace = model.selectedSpace }
                                .disabled(model.workspace.spaces.count < 2)
                        }
                        section(.pinned, title: "PINNED", tabs: model.selectedSpace.pinned)
                        Divider().padding(.vertical, 4)
                        section(.today, title: "TODAY", tabs: model.selectedSpace.tabs)
                        Button {
                            if let services { services.newTab() } else { model.newTab() }
                        } label: {
                            Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 11).frame(height: 38).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(.secondary).help("New Tab (⌘T)")
                    }
                    Spacer(minLength: 16)
                }.padding(.horizontal, 12)
            }
            footer
        }
        .background(accent.opacity(0.045))
        .sheet(isPresented: $creatingSpace) { SpaceEditor(model: model, space: nil) }
        .sheet(item: $editedSpace) { SpaceEditor(model: model, space: $0) }
        .sheet(isPresented: $archivePresented) { ArchiveView(model: model) }
        .alert("Delete \(deletingSpace?.name ?? "Space")?", isPresented: Binding(
            get: { deletingSpace != nil }, set: { if !$0 { deletingSpace = nil } })) {
                Button("Cancel", role: .cancel) { deletingSpace = nil }
                Button("Delete Space", role: .destructive) {
                    if let space = deletingSpace { model.removeSpace(space.id) }
                    deletingSpace = nil
                }
            } message: { Text("Its pinned, open, and archived tabs will be removed. Global favorites are kept. This cannot be undone.") }
        .alert("Rename Tab", isPresented: Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })) {
            TextField("Tab name", text: $tabTitle)
            Button("Cancel", role: .cancel) { renamingTab = nil }
            Button("Save") { renameTab(); renamingTab = nil }
        }
    }

    private func heading(_ text: String, symbol: String? = nil) -> some View {
        HStack {
            Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4)
            Spacer()
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
        }.foregroundStyle(.secondary).padding(.horizontal, 8)
    }

    private func section(_ list: TabList, title: String, tabs: [TabItem]) -> some View {
        VStack(spacing: 4) {
            heading(title)
            if tabs.isEmpty {
                Text(list == .pinned ? "Keep your essentials here" : "A fresh start")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            ForEach(tabs) { tab in
                HStack(spacing: 5) {
                    Button { select(tab.id) } label: {
                        HStack(spacing: 9) {
                            tabIcon(tab).frame(width: 20)
                            Text(tab.displayTitle).lineLimit(1).font(.system(size: 13))
                            Spacer(minLength: 0)
                            if model.tabStates[tab.id]?.isLoading == true {
                                ProgressView().controlSize(.mini).accessibilityLabel("Loading")
                            }
                        }.padding(.leading, 10).frame(height: 38).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    SymbolButton(title: list == .pinned ? "Reset to Pinned Address" : "Close Tab",
                                 symbol: list == .pinned ? "arrow.uturn.backward" : "xmark") {
                        if list == .pinned, let url = tab.homeURL { model.load(url, in: tab.id) }
                        else { model.closeTab(tab.id) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .background(tab.id == model.selectedTabID ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(tab.id == model.selectedTabID ? "Selected tab" : "Tab")
                .contextMenu { tabMenu(tab, list: list) }
                .draggable(tab.id.uuidString)
                .dropDestination(for: String.self) { items, _ in move(items, to: list, before: tab.id) }
            }
            Color.clear.frame(height: 5).contentShape(Rectangle())
        }
        .dropDestination(for: String.self) { items, _ in move(items, to: list) }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.workspace.spaces) { space in
                        Button { model.selectSpace(space.id) } label: {
                            spaceIcon(space).font(.system(size: 16)).frame(width: 40, height: 40)
                                .background(space.id == model.selectedSpace.id ? Color(cairnHex: space.colorHex).opacity(0.2) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).help(space.name).accessibilityLabel("Switch to Space: \(space.name)")
                            .contextMenu {
                                Button("Edit Space…") { editedSpace = space }
                                Button("Delete Space…", role: .destructive) { deletingSpace = space }
                                    .disabled(model.workspace.spaces.count < 2)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let id = items.first.flatMap(UUID.init(uuidString:)), model.item(id) != nil else { return false }
                                model.moveTab(id, to: .today, in: space.id)
                                return true
                            }
                    }
                    SymbolButton(title: "New Space", symbol: "plus") { creatingSpace = true }
                }
            }
            HStack {
                Button { archivePresented = true } label: { Label("Archive", systemImage: "archivebox") }
                    .buttonStyle(.plain).font(.caption)
                Spacer()
                SymbolButton(title: "Boosts", symbol: "paintbrush") { services?.sheet = .boosts }
                SymbolButton(title: "Settings", symbol: "gearshape") { services?.sheet = .preferences }
            }.foregroundStyle(.secondary)
        }.padding(.horizontal, 12).padding(.bottom, 10)
    }

    @ViewBuilder private func tabIcon(_ tab: TabItem) -> some View {
        if let image = model.favicons[tab.id] {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 17, height: 17).accessibilityHidden(true)
        } else { Image(systemName: tab.url == nil ? "circle.dotted" : "globe").foregroundStyle(.secondary).accessibilityHidden(true) }
    }

    @ViewBuilder private func tabMenu(_ tab: TabItem, list: TabList) -> some View {
        Button("Open") { select(tab.id) }
        Button("Open Alongside Current Tab") { model.splitSelected(with: tab.id) }
            .disabled(model.selectedTabID == nil || model.selectedTabID == tab.id)
        Divider()
        if list == .pinned { Button("Unpin Tab") { model.unpin(tab.id) } }
        else { Button("Pin to Space") { model.pin(tab.id) } }
        if list == .favorites { Button("Remove from Favorites") { model.unfavorite(tab.id) } }
        else { Button("Add to Favorites") { model.favorite(tab.id) } }
        if let home = tab.homeURL { Button("Reset to Saved Address") { model.load(home, in: tab.id) } }
        Button("Rename…") { tabTitle = tab.displayTitle; renamingTab = tab }
        if tab.customTitle != nil { Button("Use Page Title") { model.renameTab(tab.id, title: nil) } }
        Menu("Move to Space") {
            ForEach(model.workspace.spaces) { space in
                Button(space.name) { model.moveTab(tab.id, to: list == .pinned ? .pinned : .today, in: space.id) }
            }
        }
        Button("Move Up") { reorder(tab.id, delta: -1) }
        Button("Move Down") { reorder(tab.id, delta: 1) }
        if list == .today {
            Button("Archive Tab") {
                model.moveTab(tab.id, to: .archive)
                model.unloadTab(tab.id)
            }
        }
        Divider()
        Button(list == .today ? "Close Tab" : "Remove Tab", role: .destructive) { model.removeTab(tab.id) }
    }

    private func select(_ id: UUID) {
        if let services { services.selectTab(id) } else { model.select(id) }
    }
    private func move(_ items: [String], to list: TabList, before target: UUID? = nil) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)), model.item(id) != nil, id != target else { return false }
        let sourceLocation = model.locate(id)
        let targetLocation = target.flatMap { model.locate($0) }
        let index = TabDrop.insertionIndex(source: sourceLocation, target: targetLocation)
        model.moveTab(id, to: list, in: model.selectedSpace.id, at: index)
        return true
    }
    private func reorder(_ id: UUID, delta: Int) {
        guard let location = model.locate(id) else { return }
        model.moveTab(id, to: location.list, at: location.index + delta)
    }
    private func renameTab() {
        guard let tab = renamingTab else { return }
        model.renameTab(tab.id, title: tabTitle)
    }
}

@ViewBuilder
func spaceIcon(_ space: Space) -> some View {
    if space.icon.unicodeScalars.contains(where: { $0.value > 127 }) { Text(space.icon) }
    else { Image(systemName: space.icon) }
}

@MainActor
struct SpaceEditor: View {
    let model: BrowserModel
    let space: Space?
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var name = ""
    @ViewState<String> private var icon = "leaf"
    @ViewState<String> private var color = "#527B72"
    private let colors = ["#527B72", "#687FA0", "#A26D57", "#9B8052", "#8E6D86", "#64796A"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(space == nil ? "Make room for a new Space." : "Make this Space yours.")
                .font(.system(size: 24, design: .serif))
            TextField("Space name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Space name")
            Picker("Symbol", selection: $icon) {
                ForEach(["leaf", "house", "briefcase", "book", "sparkles", "globe", "cup.and.saucer", "camera"], id: \.self) {
                    Label($0, systemImage: $0).tag($0)
                }
            }
            HStack(spacing: 12) {
                Text("Color").font(.callout)
                ForEach(colors, id: \.self) { value in
                    Button { color = value } label: {
                        Circle().fill(Color(cairnHex: value)).frame(width: 30, height: 30)
                            .overlay(Image(systemName: "checkmark").foregroundStyle(.white).opacity(color == value ? 1 : 0))
                    }.buttonStyle(.plain).accessibilityLabel("Space color \(value)")
                        .accessibilityAddTraits(color == value ? .isSelected : [])
                }
            }
            Label("Each Space keeps separate cookies and site storage. Favorites are shared across Spaces.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let space {
                Text("Profile: \(space.profileID)").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(space == nil ? "Create Space" : "Save Changes") {
                    if let space {
                        model.updateSpace(space.id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines); $0.icon = icon; $0.colorHex = color }
                    } else { model.addSpace(name: name.trimmingCharacters(in: .whitespacesAndNewlines), icon: icon, colorHex: color) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 450)
            .onAppear { if let space { name = space.name; icon = space.icon; color = space.colorHex } }
    }
}

enum TabDrop {
    static func insertionIndex(source: TabLocation?, target: TabLocation?) -> Int? {
        guard let target else { return nil }
        guard let source, source.list == target.list, source.spaceIndex == target.spaceIndex,
              source.index < target.index else { return target.index }
        return target.index - 1
    }
}
