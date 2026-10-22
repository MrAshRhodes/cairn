import Foundation
import CairnCore
import CairnImport

extension BrowserServices {
    var importStaging: ImportStaging {
        ImportStaging(root: directory.appendingPathComponent("Import", isDirectory: true))
    }

    /// File ▸ Import… (also in the command bar). Never runs on its own.
    func presentImporter() {
        guard workspaceWritable else {
            report("Import is unavailable", detail: "Your saved session could not be read, so Cairn will not add data to it.")
            return
        }
        sheet = .importer
    }

    func makeImportSink() -> BrowserImportSink { BrowserImportSink(model: model, history: history) }

    /// Removes scratch copies left by an import that was interrupted. Call once at launch.
    func sweepImportStaging() { importStaging.sweep() }
}
