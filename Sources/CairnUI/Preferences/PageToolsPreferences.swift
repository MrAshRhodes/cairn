import SwiftUI
import CairnCore
import CairnEngineKit

/// Language and user agent settings. Edits are validated and applied together with the Apply button.
struct PageToolsPreferencesSection: View {
    let services: BrowserServices
    @ViewState<String> private var languages = ""
    @ViewState<String> private var userAgent = ""
    @ViewState<Bool> private var loaded = false

    private var languagesValid: Bool {
        languages.trimmingCharacters(in: .whitespaces).isEmpty || PagePreferences.normalizedLanguages(languages) != nil
    }
    private var userAgentValid: Bool { PagePreferences.isValidUserAgent(userAgent.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        Section("Language and identity") {
            TextField("Preferred languages", text: $languages, prompt: Text(PagePreferences.systemLanguages()))
            Text(languagesValid ? "Comma-separated, most preferred first, e.g. de-DE,de,en. Empty follows your Mac's language list. Sent as Accept-Language and used for navigator.languages."
                                : "Enter language tags such as en-US or de.")
                .font(.caption).foregroundStyle(languagesValid ? Color.secondary : Color.red)
            TextField("User agent override", text: $userAgent, prompt: Text("Chromium default"))
            Text(userAgentValid ? "Advanced. Leave empty so sites see Chromium's real identity; a custom string also drops the matching client hints."
                                : "The user agent must be printable ASCII and at most \(PagePreferences.maximumUserAgentLength) characters.")
                .font(.caption).foregroundStyle(userAgentValid ? Color.secondary : Color.red)
            HStack {
                Spacer()
                Button("Apply") {
                    services.settings.acceptLanguages = PagePreferences.normalizedLanguages(languages) ?? ""
                    services.settings.userAgent = userAgent.trimmingCharacters(in: .whitespaces)
                    services.saveSettings()
                }.disabled(!languagesValid || !userAgentValid)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            languages = services.settings.acceptLanguages
            userAgent = services.settings.userAgent
        }
    }
}
