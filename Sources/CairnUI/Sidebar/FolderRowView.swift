import SwiftUI
import CairnCore

/// Header row of a pinned-tab folder. Drag payloads use the `folder:` prefix so tab drops ignore them.
struct FolderRowView: View {
    static let dragPrefix = "folder:"
    let folder: TabFolder
    let depth: Int
    let itemCount: Int
    let accent: Color
    var toggle: () -> Void
    var rename: () -> Void
    var addSubfolder: () -> Void
    var delete: () -> Void
    var dropTab: ([String]) -> Bool

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(folder.collapsed ? 0 : 90)).frame(width: 12)
                Image(systemName: folder.collapsed ? "folder" : "folder.fill").foregroundStyle(accent)
                Text(folder.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if folder.collapsed {
                    Text("\(itemCount)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 8 + CGFloat(depth) * 14).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Folder \(folder.name), \(folder.collapsed ? "collapsed" : "expanded"), \(itemCount) tabs")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button(folder.collapsed ? "Expand" : "Collapse", action: toggle)
            Button("Rename Folder…", action: rename)
            Button("New Subfolder…", action: addSubfolder).disabled(depth + 1 >= TabFolder.maximumDepth)
            Divider()
            Button("Delete Folder (Keep Tabs)", role: .destructive, action: delete)
        }
        .draggable(Self.dragPrefix + folder.id.uuidString)
        .dropDestination(for: String.self) { items, _ in dropTab(items) }
    }
}
