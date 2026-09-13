# Security reports

For vulnerabilities, use the repository's private GitHub vulnerability-reporting form when available. Do not post exploit details, credentials or private files in a public issue. If private reporting is unavailable, open an issue requesting a private contact without including sensitive details.

Ambient is an early preview without a guaranteed response time. The current release is the only supported line.

Web wallpapers run imported JavaScript and may access the network. Use trusted content. Custom HTML/CSS widgets are a separate offline renderer: page scripts, remote resources, frames and native command access are disabled. The app is not a security boundary for arbitrary hostile wallpaper files.

Builds are currently ad-hoc signed and not notarized. Verify release origins and checksums. Never disable Gatekeeper globally to run Ambient.
