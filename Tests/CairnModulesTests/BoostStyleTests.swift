import Foundation
import JavaScriptCore
import Testing
@testable import CairnBoosts

@Suite struct BoostStyleTests {
    @Test func emptyInputCompilesToNothing() {
        #expect(BoostCSSCompiler.compile(style: nil, zapped: nil) == "")
        #expect(BoostCSSCompiler.compile(style: BoostStyle(invertLightness: false, contrast: 1), zapped: []) == "")
    }

    @Test func goldenOutputIsDeterministic() {
        let style = BoostStyle(tintHex: "#FF8800", tintAmount: 0.2, invertLightness: true, contrast: 1.1, fontScale: 1.25, textCase: .uppercase)
        let css = BoostCSSCompiler.compile(style: style, zapped: ["div.ad:nth-of-type(2)", "[id=\"banner\"]"])
        #expect(css == """
        /* cairn visual edits */
        html { filter: invert(1) hue-rotate(180deg) contrast(1.1) !important; }
        img, picture, video, canvas, iframe { filter: invert(1) hue-rotate(180deg) !important; }
        html::after { content: ""; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none; background: #ff8800; opacity: 0.2; mix-blend-mode: color; }
        html { font-size: 125% !important; }
        body :where(p, li, a, span, div, h1, h2, h3, h4, h5, h6, td, th, label, button, input, textarea, select, blockquote, dd, dt) { text-transform: uppercase !important; }
        div.ad:nth-of-type(2),
        [id="banner"] { display: none !important; }
        """)
        #expect(css == BoostCSSCompiler.compile(style: style, zapped: ["div.ad:nth-of-type(2)", "[id=\"banner\"]"]))
    }

    @Test func unsafeZapSelectorsNeverReachCSS() {
        let css = BoostCSSCompiler.compile(style: nil, zapped: ["a{}b", "div, body", "p > ", "x[onclick=\"1\"]", "ul > li.item"])
        #expect(css.contains("ul > li.item"))
        #expect(!css.contains("a{}b") && !css.contains("body") && !css.contains("onclick"))
    }

    @Test(arguments: ["div", "div > p.x:nth-of-type(2)", "a[id=\"a-b_c\"]", "html > body"])
    func safeSelectors(selector: String) { #expect(ZapSelector.isSafe(selector)) }

    @Test(arguments: ["", "div p", "div,p", "*", "div:hover", "div[onclick]", "a\nb", "div > ", "} body {"])
    func unsafeSelectors(selector: String) { #expect(!ZapSelector.isSafe(selector)) }

    @Test func validationRejectsOutOfRangeStyleAndTooManyZaps() {
        var boost = Boost(name: "A", hostPatterns: ["example.com"], style: BoostStyle(contrast: 9))
        #expect(throws: BoostError.self) { try boost.validate() }
        boost.style = BoostStyle(tintHex: "red")
        #expect(throws: BoostError.self) { try boost.validate() }
        boost.style = nil
        boost.zapped = Array(repeating: "div", count: 201)
        #expect(throws: BoostError.self) { try boost.validate() }
        boost.zapped = ["div"]
        #expect(throws: Never.self) { try boost.validate() }
    }

    @Test func oldBoostFileWithoutStyleDecodes() throws {
        let json = #"{"id":"3C1B8E3A-0000-4000-8000-000000000001","name":"Old","hostPatterns":["example.com"],"css":"a{}","js":"","isEnabled":true}"#
        let boost = try JSONDecoder().decode(Boost.self, from: Data(json.utf8))
        #expect(boost.style == nil && boost.zapped == nil)
        #expect(boost.effectiveCSS == "a{}")
    }

    @Test func effectiveCSSPrependsVisualEdits() {
        let boost = Boost(name: "A", hostPatterns: ["example.com"], css: "a{}", zapped: ["div"])
        #expect(boost.effectiveCSS.hasSuffix("a{}") && boost.effectiveCSS.contains("div { display: none"))
    }

    @Test func pickerBuilderEmitsOnlyGrammarSelectors() throws {
        let context = try #require(JSContext())
        // A tiny DOM stand-in: enough structure for the builder to walk.
        context.evaluateScript("""
        function el(tag, id, cls, parent) {
            var e = { nodeType: 1, tagName: tag.toUpperCase(), id: id || '', classList: cls || [], parentElement: parent || null, children: [] };
            if (parent) { parent.children.push(e); }
            return e;
        }
        var html = el('html'), body = el('body', '', [], html);
        var a = el('div', '', ['x"y', 'ad'], body), b = el('div', 'main-1', [], body), c = el('div', '', ['ad'], body);
        var evil = el('div', 'a"] {', [], body);
        """)
        context.evaluateScript(ZapPickerScript.selectorBuilder)
        for expression in ["selectorBuilder(c, function () { return false; })", "selectorBuilder(a, function () { return false; })",
                           "selectorBuilder(b, function (s) { return true; })", "selectorBuilder(evil, function () { return false; })"] {
            let value = try #require(context.evaluateScript(expression)).toString() ?? ""
            #expect(ZapSelector.isSafe(value), "\(value)")
        }
        #expect(context.evaluateScript("selectorBuilder(c, function () { return false; })").toString() == "html > body > div.ad:nth-of-type(3)")
        #expect(context.evaluateScript("selectorBuilder(b, function (s) { return true; })").toString() == "div[id=\"main-1\"]")
    }
}

@Suite struct BoostExchangeTests {
    @Test func roundTripAssignsFreshIDsAndKeepsCSSOnlyEnabled() throws {
        let original = Boost(name: "Calm", hostPatterns: ["example.com"], css: "a{color:red}", style: BoostStyle(contrast: 1.2), zapped: ["div.ad"])
        let result = try BoostExchange.importBoosts(from: BoostExchange.export([original]))
        let imported = try #require(result.boosts.first)
        #expect(imported.id != original.id)
        #expect(imported.isEnabled && result.needsReview.isEmpty)
        #expect(imported.style == original.style && imported.zapped == original.zapped && imported.css == original.css)
    }

    @Test func scriptsAndRemoteCSSImportDisabled() throws {
        let js = Boost(name: "JS", hostPatterns: ["example.com"], js: "alert(1)")
        let remote = Boost(name: "Remote", hostPatterns: ["example.com"], css: "@import url(https://evil.test/x.css);")
        let url = Boost(name: "Url", hostPatterns: ["example.com"], css: "a{background:url( 'https://evil.test/p.png')}")
        let local = Boost(name: "Local", hostPatterns: ["example.com"], css: "a{background:url(data:image/png;base64,AA)}")
        let result = try BoostExchange.importBoosts(from: BoostExchange.export([js, remote, url, local]))
        #expect(result.boosts.map(\.isEnabled) == [false, false, false, true])
        #expect(result.needsReview.count == 3)
    }

    @Test func rejectsBadFiles() throws {
        #expect(throws: BoostError.self) { try BoostExchange.importBoosts(from: Data("nope".utf8)) }
        #expect(throws: BoostError.self) { try BoostExchange.importBoosts(from: Data(#"{"format":"other","schemaVersion":1,"boosts":[]}"#.utf8)) }
        #expect(throws: BoostError.self) { try BoostExchange.importBoosts(from: Data(#"{"format":"cairn-boost","schemaVersion":2,"boosts":[]}"#.utf8)) }
        #expect(throws: BoostError.self) { try BoostExchange.importBoosts(from: Data(count: BoostExchange.maximumBytes + 1)) }
        let many = (0..<101).map { Boost(name: "B\($0)", hostPatterns: ["example.com"]) }
        #expect(throws: BoostError.self) { try BoostExchange.importBoosts(from: BoostExchange.export(many)) }
        let bad = Boost(name: "Bad", hostPatterns: ["https://example.com"])
        #expect(throws: BoostError.self) { try BoostExchange.importBoosts(from: BoostExchange.export([bad])) }
    }
}
