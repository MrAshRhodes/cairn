import SwiftUI
import CairnCore
import CairnEngineKit
import CairnUpdater

@MainActor
public struct PreferencesView: View {
    let model: BrowserModel
    let services: BrowserServices?
    @ViewState<String> private var selectedTab = "general"
    @ViewState<Bool> private var clearHistoryConfirmation = false
    @ViewState<Bool> private var automaticUpdates = false
    @ViewState<ModuleScriptReview?> private var scriptReview = nil
    public init(model: BrowserModel, services: BrowserServices? = nil) {
        self.model = model
        self.services = services
    }

    public var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Make yourself at home.", subtitle: "Cairn settings · local to this Mac")
            if let services {
                TabView(selection: $selectedTab) {
                    general(services).tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag("general")
                    privacy(services).tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
                    SitePermissionsView(services: services).tabItem { Label("Permissions", systemImage: "checkmark.shield") }.tag("permissions")
                    updates(services).tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag("updates")
                    LinksPane(services: services).tabItem { Label("Links", systemImage: "link") }.tag("links")
                    modules(services).tabItem { Label("Modules", systemImage: "puzzlepiece.extension") }.tag("modules")
                    SiteSearchPane(services: services).tabItem { Label("Site Search", systemImage: "magnifyingglass") }.tag("site-search")
                    Button("Edit Keyboard Shortcuts…") { services.sheet = .shortcuts }
                        .tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
                }.padding(.horizontal, 18).padding(.bottom, 18)
            } else {
                ContentUnavailableView("Settings require an app session", systemImage: "gearshape",
                    description: Text("The browser is using \(model.engine.displayName). Open Settings from the Cairn application menu."))
            }
        }
        .frame(width: 680, height: 570)
        .onAppear { automaticUpdates = services?.updater.automaticallyChecks ?? false }
        .sheet(item: $scriptReview) { review in
            ScriptTrustReview(title: review.title, source: review.source, scope: "This module command runs on the active page when invoked.",
                              onAllow: review.allow)
        }
        .alert("Clear browsing history?", isPresented: $clearHistoryConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { services?.clearHistory() }
        } message: { Text("All locally recorded visits will be removed. Your tabs, pins, and favorites are kept.") }
    }

    private func general(_ services: BrowserServices) -> some View {
        @Bindable var settings = services.settings
        return Form {
            Section("Browsing") {
                Picker("Search engine", selection: $settings.searchTemplate) {
                    Text("DuckDuckGo").tag("https://duckduckgo.com/?q=%s")
                    Text("Google").tag("https://www.google.com/search?q=%s")
                    Text("Bing").tag("https://www.bing.com/search?q=%s")
                    if !["https://duckduckgo.com/?q=%s", "https://www.google.com/search?q=%s", "https://www.bing.com/search?q=%s"].contains(settings.searchTemplate) {
                        Text("Custom").tag(settings.searchTemplate)
                    }
                }
                Toggle("Restore ordinary tabs at launch", isOn: $settings.restoreSessionOnLaunch)
                Text("Spaces, pins, favorites, and archived tabs are always kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Archive inactive tabs after", selection: $settings.autoArchiveAfterHours) {
                    Text("Never").tag(0.0)
                    Text("12 hours").tag(12.0)
                    Text("1 day").tag(24.0)
                    Text("1 week").tag(168.0)
                    Text("1 month").tag(720.0)
                }
                Text("Pinned tabs, favorites, and your selected tab are never automatically archived.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                HStack {
                    Text("Sidebar width")
                    Slider(value: $settings.sidebarWidth, in: 200...420, step: 10)
                    Text("\(Int(settings.sidebarWidth))").font(.caption.monospacedDigit()).frame(width: 32)
                }
            }
            PageToolsPreferencesSection(services: services)
            if !services.settingsWritable {
                Label("Settings are read-only because their saved file could not be read.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }.formStyle(.grouped)
    }

    private func privacy(_ services: BrowserServices) -> some View {
        Form {
            Section("No account. No sync service.") {
                Text("Your Spaces, preferences, Boosts, and history stay in your Application Support folder. Each Space has a separate website-data profile. Global favorites are shared.")
                    .font(.callout)
                HStack {
                    Text("Saved browsing history")
                    Spacer()
                    Button("Clear History…") { clearHistoryConfirmation = true }.disabled(services.history == nil)
                }
            }
            SiteDataPreferences(services: services)
            Section("Your files") {
                Text(services.directory.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("Reveal Cairn Data Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([services.directory])
                }
                if !services.workspaceWritable || !services.settingsWritable || !services.boostsWritable {
                    Label("Recovery mode is active", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                    Text("Unreadable files are never overwritten by autosave. Quit Cairn and recover or move the affected file before relaunching. Keep a backup of the original.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }

    private func updates(_ services: BrowserServices) -> some View {
        Form {
            Section("A browser worth keeping current.") {
                Text("Cairn uses signed updates. Automatic checks are available only in a correctly signed, configured application bundle.")
                Toggle("Automatically check for updates", isOn: $automaticUpdates)
                    .disabled(services.updater.configurationError != nil)
                    .onChange(of: automaticUpdates) { _, value in services.updater.automaticallyChecks = value }
                if let error = services.updater.configurationError {
                    Label(error, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                }
                Button("Check for Updates…") { services.checkForUpdates() }
            }
            Section("This build") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                LabeledContent("Engine", value: model.engine.versionDescription)
            }
        }.formStyle(.grouped)
    }

    private func modules(_ services: BrowserServices) -> some View {
        Form {
            Section("Active modules") {
                ForEach(services.modules.modules, id: \.id) { module in
                    LabeledContent(module.displayName, value: module.version)
                }
                Section("JavaScript permissions") {
                    let commands = services.modules.allCommands(for: model).filter { services.modules.requiresJavaScriptTrust(for: $0.id) }
                    if commands.isEmpty { Text("No module commands request JavaScript.").foregroundStyle(.secondary) }
                    ForEach(commands) { command in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(command.title)
                                Text(services.modules.isJavaScriptTrusted(for: command.id) ? "Allowed this session" : "Blocked until reviewed")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if services.modules.isJavaScriptTrusted(for: command.id) {
                                Button("Revoke") {
                                    do { try services.setModuleJavaScriptTrusted(false, for: command.id) }
                                    catch { services.report("Permission could not be changed", error: error) }
                                }
                            } else {
                                Button("Review…") { scriptReview = services.moduleScriptReview(for: command, runAfterGrant: false) }
                            }
                        }
                    }
                }.id(services.moduleTrustRevision)
                if services.modules.modules.isEmpty { Text("No modules loaded.").foregroundStyle(.secondary) }
            }
            Section("Extend your workspace") {
                Text("Declarative user modules are loaded from the Modules folder at launch. Install only modules you trust: scripts can read and change the websites they target.")
                    .font(.callout)
                Button("Reveal Modules Folder") {
                    let url = services.directory.appendingPathComponent("Modules", isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch { services.report("Modules folder could not be opened", error: error) }
                }
                Text("Restart Cairn after changing installed modules.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
