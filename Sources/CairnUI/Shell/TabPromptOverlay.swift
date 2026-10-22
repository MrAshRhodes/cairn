import SwiftUI
import CairnCore
import CairnEngineKit

/// Sheet-style cards drawn over one tab's pane: site permission requests, JavaScript dialogs, HTTP sign-in and
/// the blocked-certificate page. Per pane rather than app-modal, so a page that opens dialogs only blocks itself.
@MainActor
struct TabPromptOverlay: View {
    let model: BrowserModel
    let tabID: UUID

    var body: some View {
        if let error = model.prompts.certificateErrors[tabID] {
            CertificateBlockedView(model: model, tabID: tabID, error: error)
        } else if let prompt = model.prompts.front(tabID) {
            ZStack {
                Color.black.opacity(0.25).accessibilityHidden(true)
                card(prompt).id(prompt.id)
                    .frame(width: 420)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                    .shadow(radius: 18, y: 6)
                    .accessibilityAddTraits(.isModal)
            }
        }
    }

    @ViewBuilder private func card(_ prompt: TabPrompt) -> some View {
        switch prompt {
        case .permission(let request): PermissionPromptCard(model: model, tabID: tabID, request: request)
        case .jsDialog(let request):
            JSDialogCard(model: model, tabID: tabID, request: request,
                         offersSuppression: model.prompts.offersSuppression(tabID))
        case .authentication(let request): AuthenticationCard(model: model, tabID: tabID, request: request)
        }
    }
}

private func originLabel(_ origin: String) -> String {
    guard let host = URLComponents(string: origin)?.host else { return origin }
    return host
}

struct PermissionPromptCard: View {
    let model: BrowserModel
    let tabID: UUID
    let request: EnginePermissionRequest
    @ViewState<Bool> private var remember = true

    private var site: String { originLabel(request.origin) }
    private var embedded: Bool {
        guard let top = request.topLevelURL?.host?.lowercased(), let host = URLComponents(string: request.origin)?.host?.lowercased() else { return false }
        return top != host
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: request.kinds.first?.symbol ?? "hand.raised").font(.title2).foregroundStyle(.tint)
                Text("\(site) wants to").font(.headline)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(request.kinds, id: \.self) { kind in
                    Label(kind.action.prefix(1).uppercased() + kind.action.dropFirst(), systemImage: kind.symbol)
                }
            }.font(.callout)
            if embedded, let top = request.topLevelURL?.host {
                Text("Requested by content embedded in \(top).").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Remember my choice for this site in this Space", isOn: $remember).font(.caption)
            HStack {
                Spacer()
                Button("Don't Allow") { model.answerPermission(request.id, tab: tabID, allow: false, remember: remember) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { model.answerPermission(request.id, tab: tabID, allow: true, remember: remember) }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20)
    }
}

struct JSDialogCard: View {
    let model: BrowserModel
    let tabID: UUID
    let request: EngineJSDialogRequest
    let offersSuppression: Bool
    @ViewState<String> private var text = ""
    @ViewState<Bool> private var suppress = false
    @FocusState private var focused: Bool

    private var title: String {
        let site = request.origin.isEmpty ? (model.tabStates[tabID]?.url?.host ?? "This page") : originLabel(request.origin)
        return request.kind == .beforeUnload ? (request.isReload ? "Reload this page?" : "Leave this page?") : "\(site) says"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if request.kind == .beforeUnload {
                Text("Changes you made may not be saved.").font(.callout)
            } else {
                ScrollView { Text(request.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160)
            }
            if request.kind == .prompt {
                TextField("", text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit { answer(true) }
                    .accessibilityLabel("Response")
            }
            if offersSuppression && request.kind != .beforeUnload {
                Toggle("Prevent this page from creating more dialogs", isOn: $suppress).font(.caption)
            }
            HStack {
                Spacer()
                if request.kind != .alert {
                    Button(request.kind == .beforeUnload ? "Stay on Page" : "Cancel") { answer(false) }
                        .keyboardShortcut(.cancelAction)
                }
                Button(request.kind == .beforeUnload ? (request.isReload ? "Reload" : "Leave") : "OK") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = request.defaultText; focused = request.kind == .prompt }
    }

    private func answer(_ accept: Bool) {
        // Closing an alert always counts as acknowledging it.
        model.answerJSDialog(request.id, tab: tabID, accept: accept, text: request.kind == .prompt && accept ? text : nil,
                             suppressFurther: suppress)
    }
}

struct AuthenticationCard: View {
    let model: BrowserModel
    let tabID: UUID
    let request: EngineAuthRequest
    @ViewState<String> private var username = ""
    @ViewState<String> private var password = ""
    @FocusState private var focused: Bool

    private var insecure: Bool { request.url?.scheme?.lowercased() == "http" && !request.isProxy }
    private var location: String { request.port > 0 && ![80, 443].contains(request.port) ? "\(request.host):\(request.port)" : request.host }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock").font(.title2).foregroundStyle(.tint)
                Text(request.isProxy ? "Sign in to proxy \(location)" : "Sign in to \(location)").font(.headline)
            }
            if !request.realm.isEmpty { Text("“\(request.realm)”").font(.callout).foregroundStyle(.secondary) }
            if insecure {
                Label("This connection is not encrypted. Your password would be sent in a form others on the network can read.",
                      systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            TextField("Username", text: $username).textFieldStyle(.roundedBorder).focused($focused)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).onSubmit(signIn)
            Text("Cairn does not save this password.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.answerAuthentication(request.id, tab: tabID, username: nil, password: nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In", action: signIn).keyboardShortcut(.defaultAction).disabled(username.isEmpty)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func signIn() {
        guard !username.isEmpty else { return }
        model.answerAuthentication(request.id, tab: tabID, username: username, password: password)
    }
}

/// Replaces the page. Chromium has already refused the connection; this explains why and has no "proceed".
struct CertificateBlockedView: View {
    let model: BrowserModel
    let tabID: UUID
    let error: EngineCertificateError

    var body: some View {
        let info = CertificateErrorInfo.describe(error)
        ZStack {
            Rectangle().fill(.background)
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill").font(.system(size: 40)).foregroundStyle(.red)
                Text("Your connection to \(error.url.host ?? "this site") is not private").font(.title2.weight(.semibold))
                Text("Cairn blocked this page because the site's identity could not be verified. Attackers might be trying to steal your information, such as passwords or card numbers.")
                    .font(.callout)
                Text(info.reason).font(.callout)
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 4) {
                        detail("Error", info.name)
                        if let subject = error.subject { detail("Issued to", subject) }
                        if let issuer = error.issuer { detail("Issued by", issuer) }
                        if let until = error.validUntil { detail("Expires", until.formatted(date: .abbreviated, time: .omitted)) }
                    }.padding(.top, 4)
                }
                Text("There is no option to continue anonymously past this warning. If you control this site, fix its certificate.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.tabStates[tabID]?.canGoBack == true {
                        Button("Go Back") { model.dismissCertificateError(tab: tabID); model.liveTabs[tabID]?.goBack() }
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("Try Again") { model.dismissCertificateError(tab: tabID); model.liveTabs[tabID]?.reload(ignoringCache: true) }
                    Button("Close Warning") { model.dismissCertificateError(tab: tabID) }
                }
            }
            .frame(maxWidth: 520, alignment: .leading).padding(32)
        }
        .accessibilityElement(children: .contain)
    }

    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled)
        }.font(.caption)
    }
}
