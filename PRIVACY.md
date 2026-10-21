# Privacy

Cairn has no project account system, telemetry collector or cloud-sync backend.
It does not upload your workspace, history, cookies or Boosts to the maintainer.
Websites you visit and your selected search engine still receive your requests.

Workspace state, settings, browsing history and local customizations are stored
on your Mac. Engine-managed cookie/cache/storage files also remain local.
They are not encrypted by Cairn; protect your macOS account and use FileVault
where appropriate. Spaces separate website profiles, not operating-system users.

Application update checks contact GitHub's release infrastructure and its
download/CDN hosts. These services receive ordinary request metadata such as your
IP address. Sparkle's system-profile submission should remain disabled. Building
from source contacts upstream dependency hosts.

Local JavaScript Boosts and module commands run only because you install or
invoke them. They can access information available to the page and can make
network requests. Install only customizations you trust. Cairn's absence of
telemetry cannot guarantee that a website or user-authored script never tracks
you.

Use the application's history/site-data controls for their stated scope.
Removing a Space is not a promise of forensic deletion of every associated
engine file or backup. Operating-system backups may retain old state. Avoid
submitting private URLs or page contents with bug reports.
