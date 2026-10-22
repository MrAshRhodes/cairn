import AppKit
import CairnEngineKit
import CairnChromiumEngine

extension Smoke {
    func pageText(_ tab: EngineTab) async throws -> String {
        try await js(tab, "document.body ? document.body.innerText : ''") as? String ?? ""
    }

    func pageToolsChecks() async throws {
        // Language/identity must be in place for the very first request of a new tab.
        engine.pagePreferences = PagePreferences(acceptLanguages: "de-DE,de", userAgent: "")
        let languages = make("pagetools-lang")
        try await load(languages, path: "echo.html")
        let echoed = try await pageText(languages)
        try require(echoed.contains("Accept-Language: de-DE,de"), "Accept-Language reaches the first request (\(echoed.prefix(80)))")
        try require(try await js(languages, "navigator.language === 'de-DE' && navigator.languages.join() === 'de-DE,de'") as? Bool == true,
                    "navigator.languages follows the preference")
        engine.pagePreferences = PagePreferences(acceptLanguages: "de-DE,de", userAgent: "CairnSmoke/1.0 (custom)")
        languages.reload(ignoringCache: true)
        try await wait { !languages.state.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        try require(try await pageText(languages).contains("User-Agent: CairnSmoke/1.0 (custom)"),
                    "user agent override applies to later navigations of an open tab")
        engine.pagePreferences = PagePreferences()

        // Zoom at the engine level: the CSS viewport shrinks by the zoom factor.
        let zoomed = make("pagetools-zoom")
        try await load(zoomed)
        let width = try await js(zoomed, "window.innerWidth") as? Double ?? 0
        zoomed.zoom = 1.5
        try await Task.sleep(for: .milliseconds(300))
        let narrow = try await js(zoomed, "window.innerWidth") as? Double ?? 0
        try require(width > 0 && abs(narrow - width / 1.5) < 4, "engine zoom changes the page viewport (\(width) -> \(narrow))")

        guard let tools = zoomed as? EngineTabPageTools else { throw SmokeError.failed("Tab lacks page tools") }
        for round in 1...3 {
            tools.showDevTools(inspectingAt: round == 2 ? CGPoint(x: 20, y: 20) : nil)
            try await wait { tools.hasDevTools }
            tools.closeDevTools()
            try await wait { !tools.hasDevTools }
            try await Task.sleep(for: .seconds(1.5))
        }
        try require(true, "DevTools window opens, inspects an element and closes (3 rounds)")

        let source = make("pagetools-source")
        let sourceURL = ViewSource.url(for: base.appendingPathComponent("echo.html"))!
        source.load(sourceURL)
        try await wait { !source.state.isLoading && source.state.progress >= 1 }
        try require(source.state.errorMessage == nil, "view-source: loads without error")
        try require(source.state.url == sourceURL && source.state.title.hasPrefix("view-source:"),
                    "view-source: page keeps its address and Chromium's source view title (\(source.state.title))")
        try require(try await pageText(source).contains("Accept-Language"), "view-source: shows the page's HTML")

        let printable = make("pagetools-print")
        try await load(printable, path: "print.html")
        guard let printTools = printable as? EngineTabPageTools else { throw SmokeError.failed("Tab lacks page tools") }
        let pdfURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cairn-smoke-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            printTools.printToPDF(at: pdfURL) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = result { throw SmokeError.failed("PrintToPDF failed: \(error.localizedDescription)") }
        let data = try Data(contentsOf: pdfURL)
        try require(data.starts(with: Data("%PDF-".utf8)), "PrintToPDF writes a PDF")
        guard let document = CGPDFDocument(pdfURL as CFURL), let page = document.page(at: 1) else {
            throw SmokeError.failed("PDF is not readable")
        }
        let box = page.getBoxRect(.mediaBox)
        try require(document.numberOfPages == 2 && abs(box.width - 360) < 1 && abs(box.height - 504) < 1,
                    "PDF honors @page size and page breaks (\(document.numberOfPages) pages, \(box.size))")

        let pdf = make("pagetools-pdf")
        let pdfPage = base.appendingPathComponent("doc.pdf")
        pdf.load(pdfPage)
        try await wait { !pdf.state.isLoading && pdf.state.progress >= 1 }
        try await Task.sleep(for: .seconds(1))
        let type = try await js(pdf, "document.contentType") as? String
        let embed = try await js(pdf, "!!document.querySelector('embed')") as? Bool
        print("PDF VIEWER: contentType=\(type ?? "nil") embed=\(String(describing: embed)) title=\(pdf.state.title) error=\(pdf.state.errorMessage ?? "-")")
        try require(pdf.state.errorMessage == nil && (type == "application/pdf" || embed == true), "PDF opens in Chromium's built-in viewer")
    }
}
