import AppKit
import SwiftUI
import CairnCore
import CairnEngineKit

// Disambiguate the property wrapper from the newer SDK's same-named macro.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Color {
    init(cairnHex: String) {
        let raw = cairnHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(raw, radix: 16) ?? 0x527B72
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct SymbolButton: View {
    let title: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

@MainActor
struct BrowserView: View {
    @Bindable var services: BrowserServices
    @ViewState<String> private var address = ""
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var model: BrowserModel { services.model }
    private var state: EngineTabState {
        model.selectedTabID.flatMap { model.tabStates[$0] } ?? EngineTabState(url: model.selectedTab?.url)
    }

    var body: some View {
        HStack(spacing: 0) {
            if services.sidebarVisible {
                SidebarView(model: model, showCommandBar: { services.showCommandBar(mode: .search) }, services: services)
                    .frame(width: min(max(services.settings.sidebarWidth, 200), 420))
                    .background(.regularMaterial)
            }
            VStack(spacing: 0) {
                toolbar
                if state.isLoading {
                    ProgressView(value: min(max(state.progress, 0), 1))
                        .progressViewStyle(.linear).tint(accent).frame(height: 2)
                        .accessibilityLabel("Page loading")
                }
                if !services.workspaceWritable || !services.settingsWritable {
                    HStack {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                        Text("Recovery mode · original data is preserved; affected changes will not be saved.")
                            .font(.caption)
                        Spacer()
                        Button("Details") { services.sheet = .preferences }.buttonStyle(.link)
                    }.padding(10).background(Color.orange.opacity(0.13))
                }
                if let issue = services.issues.first {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.title).font(.callout.weight(.semibold))
                            Text(issue.detail).font(.caption).textSelection(.enabled)
                        }
                        Spacer()
                        SymbolButton(title: "Dismiss notice", symbol: "xmark") { services.dismissIssue(issue.id) }
                    }.padding(12).background(.quaternary)
                }
                if services.findPresented { findBar }
                content
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding([.horizontal, .bottom], 8)
            }
            .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(cairnHex: "#F3F2ED"))
        }
        .tint(accent)
        .disabled(services.commandBarPresented)
        .allowsHitTesting(!services.commandBarPresented)
        .accessibilityHidden(services.commandBarPresented)
        .overlay {
            if services.tabSwitcher.isPresented {
                TabSwitcherView(switcher: services.tabSwitcher, model: model)
            }
        }
        .overlay {
            if services.commandBarPresented {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.22).ignoresSafeArea()
                        .onTapGesture { services.commandBarPresented = false }
                        .accessibilityHidden(true)
                    CommandBarView(model: model, commands: { services.commands() }, mode: services.commandBarMode,
                                   history: services.history, engines: { services.siteSearch.engines },
                                   report: { services.report($0, detail: $1) },
                                   dismiss: { services.commandBarPresented = false })
                        .id(services.commandBarMode)
                        .frame(width: 610).padding(.top, 100)
                }
            }
        }
        .sheet(item: $services.sheet) { sheet in
            switch sheet {
            case .preferences: PreferencesView(model: model, services: services)
            case .downloads: DownloadsView(services: services)
            case .boosts: BoostsView(services: services)
            case .archive: ArchiveView(model: model)
            case .history: HistoryView(services: services)
            case .shortcuts: ShortcutsPane(services: services)
            case .importer: ImportWizardView(services: services)
            case .moduleTrust:
                if let review = services.moduleReview {
                    ScriptTrustReview(title: review.title, source: review.source,
                                      scope: "This module command runs on the active page.",
                                      confirmTitle: review.runsAfterGrant ? "Allow & Run" : "Allow for This Session",
                                      onAllow: review.allow)
                }
            }
        }
        .onChange(of: services.addressFocusRequest) { _, _ in
            address = model.selectedTab?.url?.absoluteString ?? ""
            addressFocused = true
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                    editor.selectAll(nil)
                }
            }
        }
        .onChange(of: model.selectedTabID) { previous, _ in
            address = model.selectedTab?.url?.absoluteString ?? ""
            services.zoom = services.activeEngineTab?.zoom ?? 1
            services.findResult = nil
            if let previous { model.liveTabs[previous]?.clearFind() }
            if services.findPresented { services.find() }
        }
        .onChange(of: state.url) { _, url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
        .onChange(of: services.findPresented) { _, value in findFocused = value }
        .onChange(of: services.settings.searchTemplate) { _, _ in services.saveSettings() }
        .onChange(of: services.settings.autoArchiveAfterHours) { _, _ in services.saveSettings() }
        .onChange(of: services.settings.restoreSessionOnLaunch) { _, _ in services.saveSettings() }
        .onChange(of: services.settings.sidebarWidth) { _, _ in services.saveSettings() }
        .onAppear { address = model.selectedTab?.url?.absoluteString ?? "" }
    }

    private var accent: Color { Color(cairnHex: model.selectedSpace.colorHex) }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if !services.sidebarVisible {
                SymbolButton(title: "Show Sidebar", symbol: "sidebar.left") { services.sidebarVisible = true }
            }
            SymbolButton(title: "Back", symbol: "chevron.left") { services.activeEngineTab?.goBack() }
                .disabled(!state.canGoBack)
            SymbolButton(title: "Forward", symbol: "chevron.right") { services.activeEngineTab?.goForward() }
                .disabled(!state.canGoForward)
            SymbolButton(title: state.isLoading ? "Stop Loading" : "Reload", symbol: state.isLoading ? "xmark" : "arrow.clockwise") {
                if state.isLoading { services.activeEngineTab?.stopLoading() }
                else { services.activeEngineTab?.reload(ignoringCache: false) }
            }.disabled(model.selectedTabID == nil)
            HStack(spacing: 8) {
                Image(systemName: securitySymbol).foregroundStyle(state.url == nil || state.isSecure ? Color.secondary : Color.orange)
                    .help(securityDescription).accessibilityLabel(securityDescription)
                TextField("Search or enter a website", text: $address)
                    .textFieldStyle(.plain).focused($addressFocused)
                    .onSubmit {
                        model.navigate(address)
                        addressFocused = false
                    }
                    .onExitCommand {
                        address = model.selectedTab?.url?.absoluteString ?? ""
                        addressFocused = false
                    }
                    .accessibilityLabel("Address and search")
                if addressFocused {
                    Text("↵").foregroundStyle(.tertiary)
                } else if services.zoom != 1 {
                    Button("\(Int(services.zoom * 100))%") { services.setZoom(1) }
                        .font(.caption.monospacedDigit()).buttonStyle(.plain).help("Reset zoom")
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(addressFocused ? accent : .clear, lineWidth: 2))
            SymbolButton(title: "Split View", symbol: "rectangle.split.2x1") { services.toggleSplit() }
            SymbolButton(title: "Downloads", symbol: "arrow.down.circle") { services.sheet = .downloads }
            Menu {
                Button("Find in Page") { services.findPresented = true }
                Button("Zoom In") { services.setZoom((services.activeEngineTab?.zoom ?? 1) + 0.1) }
                Button("Zoom Out") { services.setZoom((services.activeEngineTab?.zoom ?? 1) - 0.1) }
                Button("Actual Size") { services.setZoom(1) }
                Divider()
                if let tab = model.selectedTab {
                    Button("Pin Tab") { model.pin(tab.id) }
                    Button("Add to Favorites") { model.favorite(tab.id) }
                    if let url = tab.url {
                        ShareLink(item: url) { Text("Share Page") }
                        Button("Copy Page Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                }
                Divider()
                Button("Import…") { services.presentImporter() }
                Button("Boosts…") { services.sheet = .boosts }
                Button("Settings…") { services.sheet = .preferences }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 32) }
            .menuStyle(.borderlessButton).fixedSize().help("Page actions").accessibilityLabel("Page actions")
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .padding(.top, services.sidebarVisible ? 0 : 20)
    }

    private var securitySymbol: String {
        if state.errorMessage != nil { return "exclamationmark.triangle" }
        guard state.url != nil else { return "magnifyingglass" }
        return state.isSecure ? "lock" : "globe"
    }
    private var securityDescription: String {
        guard state.url != nil else { return "Search the web" }
        return state.isSecure ? "Secure HTTPS connection" : "This page does not report a secure connection"
    }

    private var findBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: $services.findQuery)
                .textFieldStyle(.plain).focused($findFocused)
                .onSubmit { services.find() }
                .onChange(of: services.findQuery) { _, _ in services.find() }
                .onExitCommand { services.closeFind() }
                .accessibilityLabel("Find in page")
            if let found = services.findResult {
                Text(found ? "Match found" : "No matches").font(.caption).foregroundStyle(found ? Color.secondary : .red)
                    .accessibilityLabel(found ? "Match found" : "No matches")
            }
            SymbolButton(title: "Previous Match", symbol: "chevron.up") { services.find(forward: false) }
            SymbolButton(title: "Next Match", symbol: "chevron.down") { services.find() }
            SymbolButton(title: "Close Find", symbol: "xmark") { services.closeFind() }
        }.padding(.horizontal, 16).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if let group = model.activeSplit {
            SplitContainerView(model: model, group: group) { id in pane(id, split: true) }
        } else if let id = model.selectedTabID, model.item(id) != nil {
            pane(id, split: false)
        } else { StartPage(services: services) }
    }

    private func pane(_ id: UUID, split: Bool) -> some View {
        VStack(spacing: 0) {
            if split {
                HStack {
                    Button {
                        services.selectTab(id)
                    } label: {
                        HStack {
                            Circle().fill(id == model.selectedTabID ? accent : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                            Text(model.item(id)?.displayTitle ?? "New Tab").lineLimit(1)
                            Spacer()
                        }.padding(8).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Focus \(model.item(id)?.displayTitle ?? "pane")")
                    SymbolButton(title: "Remove Pane from Split View", symbol: "xmark") {
                        model.removeFromSplit(id)
                    }
                }.font(.caption).background(.regularMaterial)
            }
            TabHealthBanner(model: model, tabID: id)
            if let error = model.tabStates[id]?.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Try Again") { model.liveTab(for: id)?.reload(ignoringCache: false) }
                }.padding(16).background(Color.orange.opacity(0.1))
            }
            if let blocked = model.blockedPopups[id], blocked > 0 {
                HStack {
                    Image(systemName: "rectangle.on.rectangle.slash")
                    Text(blocked == 1 ? "A popup was blocked" : "\(blocked) popups were blocked").font(.callout)
                    Spacer()
                    Button("Dismiss") { model.dismissBlockedPopups(id) }
                }.padding(12).background(Color.yellow.opacity(0.12))
            }
            if model.item(id)?.url == nil {
                StartPage(services: services, tabID: id)
            } else {
                EngineHost(model: model, tabID: id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .overlay { TabPromptOverlay(model: model, tabID: id) }
        .overlay(alignment: .bottomLeading) {
            if split && model.selectedTabID != id {
                Button("Focus pane") { services.selectTab(id) }
                    .buttonStyle(.bordered).font(.caption).padding(8)
            }
        }
    }
}

@MainActor
struct EngineHost: NSViewRepresentable {
    let model: BrowserModel
    let tabID: UUID
    final class Coordinator {
        weak var container: NSView?
        var monitor: Any?
        let model: BrowserModel
        var tabID: UUID
        init(model: BrowserModel, tabID: UUID) { self.model = model; self.tabID = tabID }
        func attach(_ view: NSView) {
            container = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let container = self.container, container.window === event.window else { return }
                    let point = container.convert(event.locationInWindow, from: nil)
                    if container.bounds.contains(point), self.model.selectedTabID != self.tabID {
                        self.model.select(self.tabID)
                    }
                }
                return event
            }
        }
        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model, tabID: tabID) }
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.attach(container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.tabID = tabID
        guard let view = model.liveTab(for: tabID)?.view else { return }
        guard container.subviews.first !== view else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
        // Keep the engine tab alive while switching Spaces; only detach the visible host.
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}

@MainActor
private struct StartPage: View {
    let services: BrowserServices
    var tabID: UUID?
    @ViewState<String> private var query = ""
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "mountain.2").font(.system(size: 45, weight: .ultraLight))
                .foregroundStyle(Color(cairnHex: services.model.selectedSpace.colorHex))
                .accessibilityHidden(true)
            VStack(spacing: 9) {
                Text("A little room to explore.").font(.system(size: 32, weight: .regular, design: .serif))
                Text("Your tabs, your Spaces. Nothing to sign in to.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Where would you like to go?", text: $query)
                    .textFieldStyle(.plain).accessibilityLabel("Search or website")
                    .onSubmit {
                        if let tabID { services.selectTab(tabID) }
                        services.model.navigate(query)
                    }
                Text("↵").foregroundStyle(.tertiary)
            }.padding(16).frame(maxWidth: 440)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 24) {
                Label("New tab  ⌘T", systemImage: "plus")
                Label("Find anything  ⌘K", systemImage: "command")
            }.font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("CAIRN  /  \(services.model.selectedSpace.name.uppercased())")
                .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2)
                .foregroundStyle(.tertiary).padding(.bottom, 24)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
