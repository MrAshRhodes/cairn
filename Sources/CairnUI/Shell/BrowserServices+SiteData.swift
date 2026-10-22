import AppKit
import CairnCore
import CairnEngineKit

extension BrowserServices {
    var contentBlockingURL: URL { directory.appendingPathComponent("content-blocking.json") }

    /// Clears every Space's website data (cookies, cache and storage).
    public func clearSiteData() async {
        await clearSiteData(kinds: .all, site: nil, spaceIDs: nil)
    }

    /// Clears website data for `spaceIDs` (nil = every Space), optionally for one site only.
    public func clearSiteData(kinds: SiteDataKinds, site: String?, spaceIDs: Set<UUID>?) async {
        guard !privacyBusy, !kinds.isEmpty else { return }
        privacyBusy = true
        defer { privacyBusy = false }
        let spaces = model.workspace.spaces.filter { spaceIDs?.contains($0.id) ?? true }
        let profiles = Set(spaces.map(\.profileID)).sorted()
        var failures: [String] = []
        for profile in profiles {
            if let engine = model.engine as? EngineSiteDataManaging {
                failures += await engine.clearSiteData(profileID: profile, site: site, kinds: kinds).failures
            } else {
                var legacy = Set<BrowsingDataKind>()
                if kinds.contains(.cookies) { legacy.insert(.cookies) }
                if kinds.contains(.cache) { legacy.insert(.cache) }
                if kinds.contains(.storage) { legacy.insert(.localStorage) }
                await model.engine.clearBrowsingData(profileID: profile, kinds: legacy)
            }
        }
        var seen = Set<String>()
        failures = failures.filter { seen.insert($0).inserted }
        siteDataNotice = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// Profile directories that no Space references are leftovers of removed Spaces: delete them. Skipped
    /// unless the saved workspace was read successfully, so a damaged file can never orphan live profiles.
    func removeOrphanProfiles() {
        guard workspaceWritable, !model.workspace.spaces.isEmpty,
              let engine = model.engine as? EngineSiteDataManaging else { return }
        engine.removeOrphanProfiles(keeping: Set(model.workspace.spaces.map(\.profileID)))
    }

    func loadContentBlocking() {
        do { contentBlocking = try ContentBlockingStore.load(from: contentBlockingURL) }
        catch {
            contentBlockingWritable = false
            report("Content blocking settings could not be read",
                   detail: "\(error.localizedDescription)\nThe original file is preserved. Blocking is off this session.")
        }
        contentBlocking.onChange = { [weak self] in self?.contentBlockingDidChange() }
        applyContentBlocking()
    }

    func contentBlockingDidChange() {
        applyContentBlocking()
        guard contentBlockingWritable else { return }
        do { try contentBlocking.save(to: contentBlockingURL) }
        catch { report("Content blocking settings could not be saved", error: error) }
    }

    func applyContentBlocking() {
        (model.engine as? EngineSiteDataManaging)?.configureContentBlocking(
            contentBlockingWritable ? contentBlocking.configuration : ContentBlockingConfiguration())
    }

    /// Imports a local blocklist file. Nothing is fetched from the network.
    public func importBlocklist(from url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= ContentBlocklist.maximumBytes else {
                throw ServiceError.invalidData("The blocklist must be a regular text file under 16 MB.")
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            try contentBlocking.importList(text, name: url.lastPathComponent)
        } catch { report("Blocklist could not be imported", error: error) }
    }

    public var blockedRequestCount: Int { (model.engine as? EngineSiteDataManaging)?.blockedRequestCount ?? 0 }
}
