# Distribution and signing

`VERSION` is the single release-version source. `scripts/config.sh` defines paths and an optional `BUILD_NUMBER`. Builds write only to `dist/` unless `DIST_DIR` is explicitly supplied. The established bundle identifiers remain stable so local installations keep their preferences.

## Development builds

```sh
./scripts/build-app.sh
LAYOUT_PYTHON="$PWD/.venv/bin/python" ./scripts/build-dmg.sh
```

Without `SIGNING_IDENTITY`, the app and setup receive ad-hoc signatures. These signatures do **not** establish Apple developer identity or notarization. The initial public preview uses this development-signing path. SHA-256 checksums detect accidental changes but do not replace Apple signing.

The DMG contains one visible Animated Setup app, with Ambient embedded in its Helpers directory. Setup copies a complete app through a staging folder and will not overwrite existing installations. Finder automation, if allowed, closes only the containing read-only installer window. It does not disable Gatekeeper or install a privileged helper.

## Apple-trusted releases

Apple Developer ID and notarization require Apple Developer Program membership. Apple lists the annual membership at US$99 or local equivalent. Open-source status alone does not provide a fee waiver. Qualifying organizations may apply through Apple's program.

- [Membership comparison](https://developer.apple.com/support/compare-memberships/)
- [Developer ID](https://developer.apple.com/developer-id/)
- [Fee-waiver eligibility](https://developer.apple.com/help/account/membership/fee-waivers)

After the account holder installs a Developer ID Application certificate and private key in Keychain:

```sh
export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export LAYOUT_PYTHON="$PWD/.venv/bin/python"
./scripts/build-dmg.sh
```

This signs Ambient first, the containing setup second, and the DMG last, with hardened runtime on executables and secure timestamps. It verifies each signature. Signatures must be tested with actual credentials before describing a release as trusted.

Store notarization credentials directly in Keychain, outside the repository:

```sh
xcrun notarytool store-credentials AmbientNotary
export NOTARY_PROFILE=AmbientNotary
./scripts/notarize.sh
```

The script rejects ad-hoc artifacts, submits the DMG, requires an **Accepted** result, staples and validates its ticket, assesses the DMG with Gatekeeper, and regenerates the checksum. If rejected, use the submission ID with `notarytool log` and resolve the reported issue. The Developer ID/notarization path has not been exercised without an enrolled account and certificate.

Do not commit certificates, private keys, provisioning files, Keychain databases, tokens, or passwords. Do not upload signing material to an issue. Test an actual quarantined download on a separate Mac before publishing a trusted release, including opening setup and the installed app. The DMG ticket is stapled; individual extracted app bundles are not separately stapled by this script.

## GitHub releases

CI validates formatting, tests and arm64 app packaging without secrets. It uploads development build artifacts only; it does not automatically label them trusted or publish them as releases.

A maintainer builds and verifies a DMG locally, then publishes it and its `.sha256` file. Preview releases must say they are ad-hoc signed and not notarized. Use the repository's exact source commit and `VERSION`. Verify that no personal wallpaper assets or local paths enter the archive.

The water-flow shader port's redistribution rights remain unresolved; see THIRD-PARTY-NOTICES.md before downstream distribution. No downloaded wallpaper media is included.
