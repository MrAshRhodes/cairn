import CoreGraphics
import Foundation
import Testing
@testable import CairnCore

@Suite struct SplitLayoutTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func pair() throws -> SplitLayout {
        try #require(SplitLayout(tab: a).adding(b, beside: a, edge: .right))
    }

    @Test func edgesDecideAxisAndOrder() throws {
        let right = try pair()
        #expect(right.tabIDs == [a, b])
        #expect(right.axis == .horizontal)
        let left = try #require(SplitLayout(tab: a).adding(b, beside: a, edge: .left))
        #expect(left.tabIDs == [b, a])
        let bottom = try #require(SplitLayout(tab: a).adding(b, beside: a, edge: .bottom))
        #expect(bottom.axis == .vertical && bottom.tabIDs == [a, b])
        let top = try #require(SplitLayout(tab: a).adding(b, beside: a, edge: .top))
        #expect(top.tabIDs == [b, a])
    }

    @Test func threeAndFourPaneLayouts() throws {
        // 1 + 2: a on the left, b over c on the right
        let three = try #require(try pair().adding(c, beside: b, edge: .bottom))
        let frames = three.frames(in: bounds, divider: 0)
        #expect(frames[a] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(frames[b] == CGRect(x: 500, y: 0, width: 500, height: 300))
        #expect(frames[c] == CGRect(x: 500, y: 300, width: 500, height: 300))
        // 2 x 2
        let four = try #require(three.adding(d, beside: a, edge: .bottom))
        let grid = four.frames(in: bounds, divider: 0)
        #expect(four.paneCount == 4)
        #expect(grid[a] == CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(grid[d] == CGRect(x: 0, y: 300, width: 500, height: 300))
    }

    @Test func sameAxisSiblingsFlattenAndShareSpace() throws {
        let three = try #require(try pair().adding(c, beside: b, edge: .right))
        #expect(three.children.count == 3)
        let ratios = three.ratios
        #expect(abs(ratios.reduce(0, +) - 1) < 1e-9)
        #expect(abs(ratios[0] - 0.5) < 1e-9 && abs(ratios[1] - 0.25) < 1e-9 && abs(ratios[2] - 0.25) < 1e-9)
    }

    @Test func limitsAndRejections() throws {
        var layout = try pair()
        layout = try #require(layout.adding(c, beside: b, edge: .right))
        layout = try #require(layout.adding(d, beside: c, edge: .right))
        #expect(layout.adding(e, beside: a, edge: .left) == nil)
        #expect(try pair().adding(a, beside: b, edge: .right) == nil)
        #expect(try pair().adding(c, beside: d, edge: .right) == nil)
    }

    @Test func removingCollapsesAndReturnsSpace() throws {
        let three = try #require(try pair().adding(c, beside: b, edge: .bottom))
        let two = try #require(three.removing(c))
        #expect(two.tabIDs == [a, b] && two.axis == .horizontal)
        #expect(SplitLayout(tab: a).removing(a) == nil)
        let single = try #require(try pair().removing(a))
        #expect(single.tabIDs == [b] && single.isLeaf)
        let weighted = SplitLayout(axis: .horizontal, children: [.init(tab: a), .init(tab: b), .init(tab: c)], ratios: [0.5, 0.3, 0.2])
        let reduced = try #require(weighted.removing(b))
        #expect(abs(reduced.ratios[0] - 0.5 / 0.7) < 1e-9)
    }

    @Test func framesRespectDividerThickness() throws {
        let frames = try pair().frames(in: bounds, divider: 10)
        #expect(frames[a]?.width == 495 && frames[b]?.minX == 505)
        let dividers = try pair().dividers(in: bounds, thickness: 10)
        #expect(dividers.count == 1)
        #expect(dividers[0].frame == CGRect(x: 495, y: 0, width: 10, height: 600))
        #expect(dividers[0].available == 990)
    }

    @Test func dividerDragIsClampedToMinimumSizes() throws {
        let layout = try pair()
        let moved = layout.movingDivider(path: [], index: 0, to: 0.7, minimumFraction: 0.2)
        #expect(abs(moved.ratios[0] - 0.7) < 1e-9 && abs(moved.ratios[1] - 0.3) < 1e-9)
        let tooFar = layout.movingDivider(path: [], index: 0, to: 0.99, minimumFraction: 0.2)
        #expect(abs(tooFar.ratios[0] - 0.8) < 1e-9)
        let tooSmall = layout.movingDivider(path: [], index: 0, to: -1, minimumFraction: 0.2)
        #expect(abs(tooSmall.ratios[0] - 0.2) < 1e-9)
        let three = try #require(layout.adding(c, beside: b, edge: .right))
        let squeezed = three.movingDivider(path: [], index: 0, to: 0.95, minimumFraction: 0.1)
        #expect(squeezed.ratios[1] >= 0.1 - 1e-9 && squeezed.ratios[2] >= 0.1 - 1e-9)
        #expect(abs(squeezed.ratios.reduce(0, +) - 1) < 1e-9)
        let divider = try #require(layout.dividers(in: bounds, thickness: 10).first)
        #expect(abs(divider.fraction(forPointer: 500, thickness: 10) - 0.5) < 1e-9)
    }

    @Test func nestedDividerDragTargetsTheOwningSplit() throws {
        let three = try #require(try pair().adding(c, beside: b, edge: .bottom))
        let divider = try #require(three.dividers(in: bounds, thickness: 0).first { $0.axis == .vertical })
        #expect(divider.path == [1])
        let moved = three.movingDivider(path: divider.path, index: divider.index, to: 0.75, minimumFraction: 0.1)
        let frames = moved.frames(in: bounds, divider: 0)
        #expect(frames[b]?.height == 450 && frames[a]?.width == 500)
    }

    @Test func repairDropsMissingDuplicatesAndExcessPanes() throws {
        let three = try #require(try pair().adding(c, beside: b, edge: .right))
        #expect(three.repaired(validTabs: [a, b, c])?.tabIDs == [a, b, c])
        #expect(three.repaired(validTabs: [a, b])?.tabIDs == [a, b])
        #expect(three.repaired(validTabs: [a]) == nil)
        let tooMany = SplitLayout(axis: .horizontal, children: [a, b, c, d, e].map { SplitLayout(tab: $0) })
        #expect(tooMany.repaired(validTabs: [a, b, c, d, e])?.tabIDs == [a, b, c, d])
        let duplicated = SplitLayout(axis: .horizontal, children: [a, b, a].map { SplitLayout(tab: $0) })
        #expect(duplicated.repaired(validTabs: [a, b])?.tabIDs == [a, b])
    }

    @Test func damagedRatiosAreNormalised() throws {
        let json = """
        {"axis":"horizontal","ratios":[0,-1,"x"],"children":[]}
        """
        #expect((try? JSONDecoder().decode(SplitLayout.self, from: Data(json.utf8))) == nil)
        let bad = SplitLayout(axis: .horizontal, children: [.init(tab: a), .init(tab: b)], ratios: [-3, .nan])
        #expect(bad.ratios == [0.5, 0.5])
        let data = try JSONEncoder().encode(try pair())
        #expect(try JSONDecoder().decode(SplitLayout.self, from: data) == (try pair()))
    }
}
