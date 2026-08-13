# Releasing Feather

Every pull request and push to `main` runs formatting, tests, shell validation, an arm64 release
build, codesign verification, and the bundle-size report on GitHub's `macos-15` runner.

Tags shaped like `v0.1.0` run the release workflow. The tag must match
`CFBundleShortVersionString` in `Resources/Info.plist`. A successful run publishes a versioned arm64
DMG and SHA-256 checksum to the repository's public GitHub Releases page.

## Developer ID distribution

Add these Actions secrets to publish a build that opens normally under Gatekeeper:

- `FEATHER_SIGNING_CERTIFICATE_P12`: base64-encoded Developer ID Application certificate and
  private key in PKCS #12 form.
- `FEATHER_SIGNING_CERTIFICATE_PASSWORD`: password for that PKCS #12 file.
- `FEATHER_NOTARY_KEY_P8`: base64-encoded App Store Connect API private key.
- `FEATHER_NOTARY_KEY_ID`: App Store Connect API key ID.
- `FEATHER_NOTARY_ISSUER_ID`: App Store Connect API issuer ID.

The workflow imports signing material into an ephemeral keychain, signs with the hardened runtime,
submits the app to Apple's notary service, staples the ticket, packages the DMG, and removes the
temporary keychain even when a step fails. GitHub stores and serves the public download; Feather
does not need a download server, updater service, or cloud account.

If no certificate secret is present, the workflow still publishes an explicitly suffixed
`-unsigned.dmg` as a prerelease. Its release notes direct users to macOS's per-app **Open Anyway**
action in Privacy & Security; they never recommend disabling Gatekeeper. A partial signing-secret
configuration fails closed.

## Local dry run

Build and package the current source version without publishing:

```sh
FEATHER_RELEASE_VERSION=0.1.0 ./scripts/build-app.sh
FEATHER_RELEASE_VERSION=0.1.0 FEATHER_DISTRIBUTION_MODE=unsigned \
  ./scripts/package-release.sh
```

For a local Developer ID build, set `FEATHER_SIGN_IDENTITY` while building. Configure a
`notarytool` keychain profile, set `FEATHER_NOTARY_PROFILE`, and run `scripts/notarize-app.sh`
before packaging.
