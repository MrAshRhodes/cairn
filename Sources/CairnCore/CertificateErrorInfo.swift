import Foundation
import CairnEngineKit

/// Plain-language text for a blocked TLS certificate. Cairn offers no way to continue past one.
public struct CertificateErrorInfo: Equatable, Sendable {
    public var name: String
    public var reason: String

    public static func describe(_ error: EngineCertificateError, now: Date = Date()) -> CertificateErrorInfo {
        let host = error.url.host ?? "this site"
        switch error.code {
        case -200: return .init(name: "ERR_CERT_COMMON_NAME_INVALID",
            reason: "The certificate was issued for a different site name than \(host). Someone may be impersonating the site, or it is misconfigured.")
        case -201:
            var reason = "The certificate is outside its validity period."
            if let until = error.validUntil, until < now { reason = "The certificate expired on \(until.formatted(date: .abbreviated, time: .omitted))." }
            else if let from = error.validFrom, from > now { reason = "The certificate is not valid until \(from.formatted(date: .abbreviated, time: .omitted)). Check that this Mac's clock is correct." }
            return .init(name: "ERR_CERT_DATE_INVALID", reason: reason)
        case -202: return .init(name: "ERR_CERT_AUTHORITY_INVALID",
            reason: "The certificate was not issued by an authority this Mac trusts. It may be self-signed or come from a network that intercepts traffic.")
        case -206: return .init(name: "ERR_CERT_REVOKED", reason: "The issuer has revoked this certificate.")
        case -208: return .init(name: "ERR_CERT_WEAK_SIGNATURE_ALGORITHM", reason: "The certificate is signed with an algorithm that is no longer secure.")
        case -211: return .init(name: "ERR_CERT_WEAK_KEY", reason: "The certificate uses a key that is too weak to be secure.")
        case -213: return .init(name: "ERR_CERT_VALIDITY_TOO_LONG", reason: "The certificate is valid for longer than browsers allow.")
        case -214: return .init(name: "ERR_CERTIFICATE_TRANSPARENCY_REQUIRED", reason: "The certificate is missing the public log records that browsers require.")
        case -204, -205: return .init(name: error.code == -204 ? "ERR_CERT_NO_REVOCATION_MECHANISM" : "ERR_CERT_UNABLE_TO_CHECK_REVOCATION",
                                      reason: "Cairn could not confirm that the certificate has not been revoked.")
        default: return .init(name: "ERR_CERT (\(error.code))", reason: "The site's certificate failed validation.")
        }
    }
}
