import SwiftUI
import CairnCore

/// Lets features (split badge, mute/speaker button...) decorate sidebar tab rows without editing `SidebarView`.
/// A provider returns a view for a tab or nil. Providers render in registration order; re-registering an id replaces it.
@MainActor
public final class TabRowAccessoryRegistry {
    public enum Placement: Sendable { case leading, trailing }
    public static let shared = TabRowAccessoryRegistry()

    private struct Entry {
        let id: String
        let placement: Placement
        let provider: (TabItem) -> AnyView?
    }
    private var entries: [Entry] = []

    public func register(id: String, placement: Placement, provider: @escaping (TabItem) -> AnyView?) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, placement: placement, provider: provider))
    }

    public func unregister(id: String) { entries.removeAll { $0.id == id } }

    public func accessories(for tab: TabItem, placement: Placement) -> [AnyView] {
        entries.filter { $0.placement == placement }.compactMap { $0.provider(tab) }
    }
}

struct TabRowAccessories: View {
    let tab: TabItem
    let placement: TabRowAccessoryRegistry.Placement
    var body: some View {
        let views = TabRowAccessoryRegistry.shared.accessories(for: tab, placement: placement)
        HStack(spacing: 4) { ForEach(views.indices, id: \.self) { views[$0] } }
    }
}
