import SwiftUI
import CairnCore

/// Renders up to four panes in a flat list positioned by the layout tree, so changing the layout moves
/// panes instead of recreating them (the engine views stay attached).
struct SplitContainerView<Pane: View>: View {
    let model: BrowserModel
    let group: SplitGroup
    var minimumPane: CGFloat = 240
    @ViewBuilder var pane: (UUID) -> Pane
    private let thickness: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let frames = group.layout.frames(in: rect, divider: thickness)
            ZStack(alignment: .topLeading) {
                ForEach(group.layout.tabIDs, id: \.self) { id in
                    let frame = frames[id] ?? .zero
                    pane(id)
                        .frame(width: max(frame.width, 0), height: max(frame.height, 0))
                        .clipped()
                        .offset(x: frame.minX, y: frame.minY)
                }
                ForEach(Array(group.layout.dividers(in: rect, thickness: thickness).enumerated()), id: \.offset) { _, divider in
                    handle(divider)
                }
            }
            .coordinateSpace(name: "split-container-\(group.id)")
        }
    }

    private func handle(_ divider: SplitDivider) -> some View {
        let horizontal = divider.axis == .horizontal
        return Color.clear
            .frame(width: divider.frame.width, height: divider.frame.height)
            .contentShape(Rectangle())
            .overlay(Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1))
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .onHover { inside in
                if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("split-container-\(group.id)"))
                .onChanged { value in
                    let position = horizontal ? value.location.x : value.location.y
                    let fraction = divider.fraction(forPointer: position, thickness: thickness)
                    let minimum = divider.available > 0 ? Double(min(minimumPane / divider.available, 0.45)) : 0.1
                    model.moveSplitDivider(group: group.id, path: divider.path, index: divider.index,
                                           to: fraction, minimumFraction: minimum)
                })
            .accessibilityLabel(horizontal ? "Resize panes horizontally" : "Resize panes vertically")
    }
}
