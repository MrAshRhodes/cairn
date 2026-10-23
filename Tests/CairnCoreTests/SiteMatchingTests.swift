import Foundation
import Testing
@testable import CairnCore

@Suite struct SiteMatchingTests {
    @Test(arguments: [
        ("https://a.b.example.co.uk/path", "example.co.uk"),
        ("https://a.example.com.au", "example.com.au"),
        ("https://a.example.co.jp", "example.co.jp"),
        ("https://a.tenant.github.io", "tenant.github.io"),
        ("https://a.tenant.blogspot.com", "tenant.blogspot.com"),
        ("https://a.bucket.s3.amazonaws.com", "bucket.s3.amazonaws.com"),
        ("https://a.b.ck", "a.b.ck"),
        ("https://a.www.ck", "www.ck"),
        ("https://a.city.kawasaki.jp", "city.kawasaki.jp"),
        ("https://a.b.kawasaki.jp", "a.b.kawasaki.jp"),
        ("https://WWW.BÜCHER.de", "xn--bcher-kva.de"),
        ("https://www.xn--bcher-kva.de", "xn--bcher-kva.de"),
        ("https://www.食狮.公司.cn", "xn--85x722f.xn--55qx5d.cn"),
        ("https://WWW.Example.COM./", "example.com"),
        ("https://co.uk", "co.uk"),
        ("https://github.io", "github.io"),
        ("http://127.0.0.1:8080", "127.0.0.1"),
        ("https://[2001:0db8:0000:0000:0000:0000:0000:0001]", "[2001:db8::1]"),
        ("http://[::1]:9090", "[::1]"),
        ("http://localhost:3000", "localhost"),
        ("http://LOCALHOST.", "localhost"),
        ("http://printer", "printer"),
        ("https://sub.example.unknown-tld", "example.unknown-tld"),
    ])
    func bundledListClassifiesSites(_ fixture: (String, String)) throws {
        #expect(SiteMatching.site(of: try #require(URL(string: fixture.0))) == fixture.1)
    }

    @Test func privateTenantsAndPublicSuffixesAreNotOneSite() throws {
        func same(_ lhs: String, _ rhs: String) throws -> Bool {
            SiteMatching.isSameSite(try #require(URL(string: lhs)), try #require(URL(string: rhs)))
        }
        #expect(try !same("https://alice.github.io", "https://bob.github.io"))
        #expect(try !same("https://github.io", "https://alice.github.io"))
        #expect(try same("https://www.bücher.de", "https://xn--bcher-kva.de"))
        #expect(try !same("http://127.0.0.1", "http://127.0.0.2"))
        #expect(try !same("http://localhost", "http://another.localhost"))
        #expect(try same("http://[::1]", "http://[0:0:0:0:0:0:0:1]"))
        // Site classification intentionally does not replace scheme/port-aware origin security.
        #expect(try same("http://example.com:8080", "https://example.com:8443"))
    }

    @Test(arguments: [
        "https://a..example.com", "https://-bad.example", "https://bad-.example", "https://bad_host.example",
        "https://999.0.0.1", "https://example.com:0", "https://example.com:65536",
        "https://user:secret@example.com", "https://.", "https://[not-an-ip]",
        "https://exa mple.com", "https://example.com..", "about:blank", "file:///example.com",
        "javascript:alert(1)", "https:///path", "/relative",
    ])
    func malformedAndNonWebURLsHaveNoSite(_ text: String) {
        guard let url = URL(string: text) else { return }
        #expect(SiteMatching.site(of: url) == nil)
        #expect(!SiteMatching.isSameSite(url, url))
    }

    @Test func rulesUseLongestMatchAndExceptionBeforeWildcard() {
        let list = PublicSuffixList(text: """
        // deterministic parser fixture
        com
        test
        *.test
        !city.test
        deep.city.test
        公司.cn
        """)
        #expect(list.registrableDomain("com") == nil)
        #expect(list.registrableDomain("a.b.test") == "a.b.test")
        #expect(list.registrableDomain("b.test") == nil)
        #expect(list.registrableDomain("a.city.test") == "city.test")
        #expect(list.registrableDomain("a.deep.city.test") == "city.test")
        #expect(list.registrableDomain("www.xn--85x722f.xn--55qx5d.cn") == "xn--85x722f.xn--55qx5d.cn")
        #expect(list.registrableDomain("a.b.unlisted") == "b.unlisted")
    }
}
