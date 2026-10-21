# Independent implementation policy

Cairn is an original browser inspired by familiar workspace concepts. It is not
Arc source code, a binary patch, a replacement Arc client, or a reconstruction
that can be recompiled from decompiler output.

Permitted reference material includes public product descriptions and bounded
observations of behavior or architecture. The initial reference inspection used
REA to read local executable metadata and bundle declarations. It did not
decompile functions, extract source, access account data or modify the reference
application. Only independently written factual summaries belong in this repo.

Do not contribute:

- Proprietary code, decompiler output, assembly dumps or reconstructed methods.
- Extracted artwork, fonts, strings catalogs, icons or other proprietary assets.
- Credentials, signing keys, copied user profiles or private service protocols.
- Login-removal patches or code impersonating the reference application's
  servers, update signing identity or bundle identity.

Write and test behavior from the [Cairn specification](reference/functional-spec.md).
Use upstream open-source components under their own licenses, obtain them from
their official distribution channels, and retain required notices.

"Clean-room" describes this project's reference/implementation boundary; it is
not a legal certification or a claim that an independently audited two-team
process took place. Arc and other third-party names remain their owners' marks.
