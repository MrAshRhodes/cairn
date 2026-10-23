import SwiftUI
import CairnImport

struct ImportMappingView: View {
    let plan: ImportPlan
    @Binding var mappings: [MigrationMapping]
    let existingSpaceNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Map your workspace").font(.headline)
            Text(ImportMigration.limitations).font(.caption).foregroundStyle(.secondary)
            Text("Matching folders are reused; duplicate pins are skipped. Existing titles, themes and storage are never replaced. Groups using the same new name combine into one Space, using the first group's theme.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(ImportMigration.groups(in: plan).enumerated()), id: \.element.id) { index, group in
                        if mappings.indices.contains(index) {
                            mappingRow(group, mapping: $mappings[index])
                        }
                    }
                    if mappings.isEmpty { Text("This source contains no bookmark groups to map.").foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
            if !plan.history.isEmpty {
                Text("\(plan.history.count) selected history entries use Cairn's local history store, not a Space.").font(.caption).monospacedDigit()
            }
        }
    }

    private func mappingRow(_ group: MigrationGroup, mapping: Binding<MigrationMapping>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.label).font(.subheadline.weight(.semibold))
            DisclosureGroup("\(group.bookmarks.count) bookmarks → pinned tabs") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(group.bookmarks.prefix(10).enumerated()), id: \.offset) { _, bookmark in
                        Text((bookmark.folderPath + [bookmark.title]).joined(separator: " / ")).font(.caption)
                        Text(bookmark.url.absoluteString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if group.bookmarks.count > 10 { Text("And \(group.bookmarks.count - 10) more…").font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("Destination", selection: mapping.conflict) {
                ForEach(MigrationConflict.allCases, id: \.self) { policy in Text(policy.rawValue).tag(policy) }
            }
            if mapping.wrappedValue.conflict == .append {
                Picker("Existing Space", selection: mapping.destinationName) {
                    Text("Choose a Space…").tag("")
                    if !existingSpaceNames.contains(mapping.wrappedValue.destinationName), !mapping.wrappedValue.destinationName.isEmpty {
                        Text("Choose a Space…").tag(mapping.wrappedValue.destinationName)
                    }
                    ForEach(Array(Set(existingSpaceNames)).sorted(), id: \.self) { name in Text(name).tag(name) }
                }
            } else if mapping.wrappedValue.conflict == .create {
                TextField("New Space name", text: mapping.destinationName)
                    .textFieldStyle(.roundedBorder)
            }
            if group.topLevelFolder != nil, mapping.wrappedValue.conflict != .skip {
                Toggle("Keep “\(group.topLevelFolder ?? "")” as a folder inside the Space", isOn: mapping.keepTopLevelFolder)
                    .font(.caption)
            }
            Divider()
        }
    }
}
