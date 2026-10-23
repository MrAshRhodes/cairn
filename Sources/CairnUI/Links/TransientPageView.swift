import AppKit
import SwiftUI
import Observation
import CairnCore
import CairnEngineKit

@MainActor @Observable
final class TransientFocus {
    var addressRequest = 0
}

@MainActor
struct TransientPageView: View {
    let services: BrowserServices
    let tabID: UUID
    var focus: TransientFocus
    @ViewState<String> private var address = ""
    @FocusState private var addressFocused: Bool
    @FocusState private var closeFocused: Bool
    @ViewState<UUID?> private var crossProfileDestination: UUID?
    private var model: BrowserModel { services.model }
    private var page: TransientPage? { model.transientPages[tabID] }
    private var quick: Bool { page?.kind == .quickWindow }
    private var state: EngineTabState { model.tabStates[tabID] ?? model.liveTabs[tabID]?.state ?? EngineTabState() }
    private var ownerName: String { model.workspace.spaces.first { $0.id == page?.spaceID }?.name ?? "Originating Space" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SymbolButton(title: quick ? "Close Quick Window" : "Close Peek", symbol: "xmark") {
                    model.dismissTransient(tabID)
                }.focused($closeFocused)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title.isEmpty ? (quick ? "Quick Window" : "Peek") : state.title)
                        .font(.headline).lineLimit(1)
                    Text("\(ownerName) profile · Not private").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if quick {
                    Menu("Open In Space") {
                        ForEach(model.workspace.spaces) { space in
                            Button(space.profileID == page?.profileID ? space.name : "\(space.name) — reload in its profile") {
                                if space.profileID == page?.profileID { promote(to: space.id) }
                                else { crossProfileDestination = space.id }
                            }
                        }
                    }.fixedSize().accessibilityLabel("Open this page in a Space")
                } else {
                    Button("Expand to Tab", systemImage: "arrow.up.left.and.arrow.down.right") { model.expandPeek() }
                        .help("Keep this live page in Today")
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
            HStack(spacing: 6) {
                SymbolButton(title: "Back", symbol: "chevron.left") { model.liveTabs[tabID]?.goBack() }
                    .disabled(!state.canGoBack)
                SymbolButton(title: state.isLoading ? "Stop Loading" : "Reload", symbol: state.isLoading ? "xmark" : "arrow.clockwise") {
                    if state.isLoading { model.liveTabs[tabID]?.stopLoading() }
                    else { model.liveTabs[tabID]?.reload(ignoringCache: false) }
                }
                Image(systemName: state.isSecure ? "lock" : "globe")
                    .foregroundStyle(state.isSecure ? Color.secondary : .orange)
                    .accessibilityLabel(state.isSecure ? "Secure HTTPS connection" : "Not a secure connection")
                if quick {
                    TextField("Search or enter a website", text: $address)
                        .textFieldStyle(.roundedBorder).focused($addressFocused)
                        .accessibilityLabel("Quick window address and search")
                        .onSubmit {
                            if let url = URLResolver.resolve(address, searchTemplate: model.searchTemplate) {
                                model.loadTransient(url, in: tabID); addressFocused = false
                            }
                        }
                } else {
                    Text(state.url?.absoluteString ?? "").font(.callout).lineLimit(1)
                        .textSelection(.enabled).accessibilityLabel("Page address: \(state.url?.absoluteString ?? "")")
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10)
            if state.isLoading {
                ProgressView(value: state.progress).progressViewStyle(.linear)
                    .accessibilityLabel("Page loading")
            }
            TabHealthBanner(model: model, tabID: tabID)
            if let error = state.errorMessage {
                HStack {
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Try Again") { model.liveTabs[tabID]?.reload(ignoringCache: false) }
                }.padding(12).background(Color.orange.opacity(0.1))
            }
            BlockedPopupBanner(model: model, tabID: tabID)
            EngineHost(model: model, tabID: tabID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { TabPromptOverlay(model: model, tabID: tabID) }
            if quick {
                Text("Not restored when closed. Open In Space keeps the page.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .background(.background)
        .disabled(model.closingTabID != nil)
        .accessibilityHidden(model.closingTabID != nil)
        .overlay {
            if let closing = model.closingTabID, quick { PageCloseOverlay(model: model, tabID: closing) }
        }
        .onAppear {
            address = state.url?.absoluteString ?? ""
            if quick && state.url == nil { addressFocused = true } else { closeFocused = true }
        }
        .onChange(of: state.url) { _, url in if !addressFocused { address = url?.absoluteString ?? "" } }
        .onChange(of: focus.addressRequest) { _, _ in addressFocused = true }
        .alert("Open in a different profile?", isPresented: Binding(get: { crossProfileDestination != nil },
                                                                    set: { if !$0 { crossProfileDestination = nil } })) {
            Button("Cancel", role: .cancel) { crossProfileDestination = nil }
            Button("Reload in Space") {
                if let destination = crossProfileDestination { promote(to: destination) }
                crossProfileDestination = nil
            }
        } message: {
            Text("This closes the current page, subject to its unsaved-changes decision, and opens its web address afresh. Form state, page history and sign-in cookies are not copied.")
        }
    }

    private func promote(to space: UUID) {
        model.promoteTransient(tabID, to: space) { id in
            guard id != nil else { return }
            NSApp.windows.first { $0.identifier?.rawValue == "CairnMainWindow" }?.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
struct PeekOverlay: View {
    let services: BrowserServices
    let tabID: UUID
    let ownerTabID: UUID?
    @ViewState<TransientFocus> private var focus = TransientFocus()
    @ViewState<Any?> private var keyMonitor = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.25).accessibilityHidden(true)
                TransientPageView(services: services, tabID: tabID, focus: focus)
                    .frame(width: max(300, min(960, geometry.size.width - 64)),
                           height: max(240, geometry.size.height - 64))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityLabel("Peek preview")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, event.window === services.model.liveTabs[tabID]?.view.window,
                      services.model.prompts.front(tabID) == nil else { return event }
                services.model.dismissTransient(tabID)
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            // Promotion keeps focus on the same page; dismissal returns it to its owner.
            let target = services.model.item(tabID) != nil ? tabID : ownerTabID
            if let target, let view = services.model.liveTabs[target]?.view {
                DispatchQueue.main.async {
                    if view.window?.isKeyWindow == true { view.window?.makeFirstResponder(view) }
                }
            }
        }
    }
}
