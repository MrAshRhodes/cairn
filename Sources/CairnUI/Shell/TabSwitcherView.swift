import AppKit
import SwiftUI
import Observation
import CairnCore

/// The ⌃Tab recent-tabs overlay. Pressing the shortcut again steps through tabs; releasing ⌃ commits.
@MainActor @Observable
public final class TabSwitcher {
    public private(set) var isPresented = false
    public private(set) var candidates: [UUID] = []
    public private(set) var index = 0
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private weak var model: BrowserModel?

    public init() {}

    nonisolated public static func nextIndex(_ current: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return (current + (forward ? 1 : count - 1)) % count
    }

    /// Starts a session on the first press and steps on later presses. Returns false when there is nothing to switch to.
    @discardableResult
    public func advance(model: BrowserModel, forward: Bool) -> Bool {
        if !isPresented {
            let space = model.selectedSpace
            let visible = Set((model.workspace.favorites + space.pinned + space.tabs).map(\.id))
            var ids = model.recentTabs.candidates(valid: visible)
            if let current = model.selectedTabID {
                ids.removeAll { $0 == current }
                ids.insert(current, at: 0)
            }
            guard ids.count > 1 else { return false }
            candidates = ids
            index = 0
            self.model = model
            isPresented = true
            installMonitors()
        }
        index = Self.nextIndex(index, count: candidates.count, forward: forward)
        return true
    }

    public func commit() {
        defer { end() }
        guard isPresented, let model, candidates.indices.contains(index) else { return }
        model.select(candidates[index])
    }

    public func cancel() { end() }

    private func end() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isPresented = false
        candidates = []
        index = 0
        model = nil
    }

    private func installMonitors() {
        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { if !event.modifierFlags.contains(.control) { self?.commit() } }
            return event
        }) { monitors.append(flags) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let escape = event.keyCode == 53
            MainActor.assumeIsolated { if escape { self?.cancel() } }
            return escape ? nil : event
        }) { monitors.append(keys) }
    }
}

struct TabSwitcherView: View {
    let switcher: TabSwitcher
    let model: BrowserModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(switcher.candidates.prefix(9).enumerated()), id: \.element) { position, id in
                HStack(spacing: 10) {
                    Image(systemName: position == 0 ? "checkmark.circle" : "rectangle.on.rectangle").frame(width: 20)
                    Text(model.item(id)?.displayTitle ?? "Tab").lineLimit(1)
                    Spacer()
                    Text(model.item(id)?.url?.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(position == switcher.index ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(position == switcher.index ? .isSelected : [])
            }
        }
        .padding(10).frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .accessibilityLabel("Recent tabs")
    }
}
