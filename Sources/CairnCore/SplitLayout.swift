import Foundation
import CoreGraphics

/// `horizontal` places children side by side; `vertical` stacks them.
public enum SplitAxis: String, Codable, Sendable {
    case horizontal, vertical
}

public enum SplitEdge: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom
    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    var insertsBefore: Bool { self == .left || self == .top }
}

public struct SplitDivider: Equatable, Sendable {
    /// Child indexes from the root to the split node that owns this divider.
    public let path: [Int]
    /// The divider sits between children `index` and `index + 1`.
    public let index: Int
    public let axis: SplitAxis
    public let frame: CGRect
    /// The owning split's rectangle and the space shared by its panes (without dividers).
    public let container: CGRect
    public let available: CGFloat

    /// Cumulative share (0...1) of the owning split that lies before a pointer position.
    public func fraction(forPointer position: CGFloat, thickness: CGFloat) -> Double {
        guard available > 0 else { return 0 }
        let origin = axis == .horizontal ? container.minX : container.minY
        let leading = position - origin - thickness * (CGFloat(index) + 0.5)
        return Double(min(max(leading / available, 0), 1))
    }
}

/// A pure tree of panes. Leaves hold tab ids; inner nodes divide their rectangle along one axis by `ratios`.
/// Rendering code can read `frames(in:)` and keep each pane in a flat list so a relayout never recreates a view.
public struct SplitLayout: Codable, Equatable, Sendable {
    public static let maximumPanes = 4
    public static let minimumPanes = 2

    public private(set) var tabID: UUID?
    public private(set) var axis: SplitAxis
    public private(set) var ratios: [Double]
    public private(set) var children: [SplitLayout]

    public init(tab: UUID) {
        tabID = tab; axis = .horizontal; ratios = []; children = []
    }

    public init(axis: SplitAxis, children: [SplitLayout], ratios: [Double]? = nil) {
        self.tabID = nil
        self.axis = axis
        self.children = children
        self.ratios = Self.normalized(ratios, count: children.count)
    }

    public var isLeaf: Bool { tabID != nil }

    /// Tab ids in reading order (also the "focus pane N" order).
    public var tabIDs: [UUID] { tabID.map { [$0] } ?? children.flatMap(\.tabIDs) }
    public var paneCount: Int { isLeaf ? 1 : children.reduce(0) { $0 + $1.paneCount } }
    public func contains(_ id: UUID) -> Bool { tabIDs.contains(id) }

    // MARK: Editing

    /// Adds `new` beside `target` on `edge`. Returns nil when the layout is full, `new` is already present or `target` is missing.
    public func adding(_ new: UUID, beside target: UUID, edge: SplitEdge) -> SplitLayout? {
        guard paneCount < Self.maximumPanes, !contains(new), contains(target) else { return nil }
        return inserting(new, beside: target, edge: edge)?.flattened()
    }

    private func inserting(_ new: UUID, beside target: UUID, edge: SplitEdge) -> SplitLayout? {
        if let tabID {
            guard tabID == target else { return nil }
            let added = SplitLayout(tab: new)
            let me = SplitLayout(tab: tabID)
            return SplitLayout(axis: edge.axis, children: edge.insertsBefore ? [added, me] : [me, added])
        }
        var copy = self
        for index in children.indices {
            let child = children[index]
            guard child.contains(target) else { continue }
            if child.isLeaf, axis == edge.axis {
                let share = ratios[index] / 2
                copy.children.insert(SplitLayout(tab: new), at: edge.insertsBefore ? index : index + 1)
                copy.ratios[index] = share
                copy.ratios.insert(share, at: edge.insertsBefore ? index : index + 1)
            } else if let replaced = child.inserting(new, beside: target, edge: edge) {
                copy.children[index] = replaced
            } else { return nil }
            return copy
        }
        return nil
    }

    /// Removes a pane; its space goes to its neighbours. Returns nil when no pane is left.
    public func removing(_ id: UUID) -> SplitLayout? {
        if let tabID { return tabID == id ? nil : self }
        var kept: [SplitLayout] = []
        var shares: [Double] = []
        for (index, child) in children.enumerated() {
            if let remaining = child.removing(id) { kept.append(remaining); shares.append(ratios[index]) }
        }
        switch kept.count {
        case 0: return nil
        case 1: return kept[0]
        default: return SplitLayout(axis: axis, children: kept, ratios: shares).flattened()
        }
    }

    /// Drops unknown and duplicate tabs and enforces the pane limits. Nil means the group must dissolve.
    public func repaired(validTabs: Set<UUID>) -> SplitLayout? {
        var seen = Set<UUID>()
        var result = pruned(validTabs, seen: &seen)
        while let current = result, current.paneCount > Self.maximumPanes, let last = current.tabIDs.last {
            result = current.removing(last)
        }
        guard let final = result, final.paneCount >= Self.minimumPanes else { return nil }
        return final.sanitized()
    }

    /// Keeps only valid tabs and the first occurrence of each.
    private func pruned(_ valid: Set<UUID>, seen: inout Set<UUID>) -> SplitLayout? {
        if let tabID { return valid.contains(tabID) && seen.insert(tabID).inserted ? self : nil }
        var kept: [SplitLayout] = []
        var shares: [Double] = []
        for (index, child) in children.enumerated() {
            if let remaining = child.pruned(valid, seen: &seen) { kept.append(remaining); shares.append(ratios[index]) }
        }
        switch kept.count {
        case 0: return nil
        case 1: return kept[0]
        default: return SplitLayout(axis: axis, children: kept, ratios: shares).flattened()
        }
    }

    /// Moves the divider after child `index` of the node at `path` to a cumulative `fraction`, keeping every
    /// pane at least `minimumFraction` of the node.
    public func movingDivider(path: [Int], index: Int, to fraction: Double, minimumFraction: Double) -> SplitLayout {
        guard let head = path.first else {
            guard !isLeaf, ratios.indices.contains(index), index + 1 < ratios.count else { return self }
            var copy = self
            var boundaries: [Double] = []
            var total = 0.0
            for ratio in ratios { total += ratio; boundaries.append(total) }
            let floor = min(max(minimumFraction, 0), 1 / Double(ratios.count))
            let lower = (index > 0 ? boundaries[index - 1] : 0) + floor
            let upper = boundaries[index + 1] - floor
            boundaries[index] = lower <= upper ? min(max(fraction, lower), upper) : (lower + upper) / 2
            var previous = 0.0
            for position in ratios.indices {
                let edge = position == ratios.count - 1 ? 1 : boundaries[position]
                copy.ratios[position] = edge - previous
                previous = edge
            }
            return copy
        }
        guard children.indices.contains(head) else { return self }
        var copy = self
        copy.children[head] = children[head].movingDivider(path: Array(path.dropFirst()), index: index,
                                                           to: fraction, minimumFraction: minimumFraction)
        return copy
    }

    // MARK: Geometry

    public func frames(in rect: CGRect, divider: CGFloat = 1) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        layout(in: rect, divider: divider) { result[$0] = $1 } onDivider: { _ in }
        return result
    }

    public func dividers(in rect: CGRect, thickness: CGFloat = 1) -> [SplitDivider] {
        var result: [SplitDivider] = []
        layout(in: rect, divider: thickness) { _, _ in } onDivider: { result.append($0) }
        return result
    }

    private func layout(in rect: CGRect, divider: CGFloat, path: [Int] = [],
                        onPane: (UUID, CGRect) -> Void, onDivider: (SplitDivider) -> Void) {
        if let tabID { onPane(tabID, rect); return }
        let extent = axis == .horizontal ? rect.width : rect.height
        let available = max(extent - divider * CGFloat(children.count - 1), 0)
        var cursor = axis == .horizontal ? rect.minX : rect.minY
        for (index, child) in children.enumerated() {
            let size = available * CGFloat(ratios[index])
            let childRect = axis == .horizontal
                ? CGRect(x: cursor, y: rect.minY, width: size, height: rect.height)
                : CGRect(x: rect.minX, y: cursor, width: rect.width, height: size)
            child.layout(in: childRect, divider: divider, path: path + [index], onPane: onPane, onDivider: onDivider)
            cursor += size
            if index < children.count - 1 {
                let frame = axis == .horizontal
                    ? CGRect(x: cursor, y: rect.minY, width: divider, height: rect.height)
                    : CGRect(x: rect.minX, y: cursor, width: rect.width, height: divider)
                onDivider(SplitDivider(path: path, index: index, axis: axis, frame: frame, container: rect, available: available))
                cursor += divider
            }
        }
    }

    // MARK: Normalisation

    private func flattened() -> SplitLayout {
        guard !isLeaf else { return self }
        var newChildren: [SplitLayout] = []
        var newRatios: [Double] = []
        for (index, raw) in children.enumerated() {
            let child = raw.flattened()
            if !child.isLeaf, child.axis == axis {
                newChildren += child.children
                newRatios += child.ratios.map { $0 * ratios[index] }
            } else {
                newChildren.append(child)
                newRatios.append(ratios[index])
            }
        }
        return SplitLayout(axis: axis, children: newChildren, ratios: newRatios)
    }

    /// Repairs ratios that were decoded from an edited or damaged file.
    private func sanitized() -> SplitLayout {
        guard !isLeaf else { return self }
        return SplitLayout(axis: axis, children: children.map { $0.sanitized() }, ratios: ratios).flattened()
    }

    private static func normalized(_ values: [Double]?, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let even = Array(repeating: 1 / Double(count), count: count)
        guard let values, values.count == count, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return even }
        let total = values.reduce(0, +)
        return values.map { $0 / total }
    }
}

/// One persistent split. A group lives in exactly one Space so profile isolation holds.
public struct SplitGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var layout: SplitLayout
    public init(id: UUID = UUID(), spaceID: UUID, layout: SplitLayout) {
        self.id = id; self.spaceID = spaceID; self.layout = layout
    }
}
