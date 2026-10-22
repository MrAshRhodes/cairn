# Security policy

Cairn is experimental. There is no security-response SLA or independent security
audit. Use a mainstream, actively patched browser for high-risk browsing.

## Reporting

Use GitHub's private vulnerability reporting when it is enabled for this
repository. Otherwise, open a public issue requesting a private contact channel
without exploit details, credentials, private URLs or personal data. Do not post
secrets in public issues.

Include the Cairn version/commit, macOS version, architecture, rendering engine
and its version, a minimal reproduction, and the impact. Prefer local synthetic
test pages over a real person's account.

## Update responsibilities

Chromium is the only engine in current source builds and future public releases.
Its security fixes depend on the pinned CEF build and a newly published Cairn release,
not on installing Google Chrome. The historical v0.1.0 WebKit preview instead
depends on supported Apple system updates.
A successful compilation is not evidence of an up-to-date or safely sandboxed
engine. Stable CEF can lag stable Chrome; the maintenance tooling must surface
that gap rather than hide it.

Only use application updates signed with the key corresponding to the installed
app's embedded public key. Protect the private update-signing key separately from
the source tree. Developer ID signing and notarization supplement update
signatures; they are not substitutes for them.

Do not disable renderer sandboxing, TLS verification or signature validation as
a workaround. Local user-authored JavaScript is trusted code, not an isolated
extension security boundary.
