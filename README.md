# Feather

Feather is an open-source, deliberately small, native macOS agent development environment for command-line agents such as `claude` and `codex`. It provides a worktree-first sidebar, multiple persistent terminal tabs per worktree, and a bounded native file/review surface without becoming a general IDE or wrapping either agent CLI.

## Download

[Download Feather from GitHub Releases](https://github.com/jiwookm/feather/releases), open the
DMG, and drag Feather to Applications. Feather is free under the MIT License and has no account,
telemetry, or paid service. It requires an Apple-silicon Mac running macOS 15 or newer; install its
small runtime dependencies with `brew install tmux ripgrep`.

Developer ID releases are signed and notarized. Until those credentials are configured, GitHub
marks the clearly named `-unsigned.dmg` as a prerelease. After the first blocked launch, use
**System Settings → Privacy & Security → Open Anyway** instead of disabling Gatekeeper. Release
checksums and all historical versions are on the
[Releases page](https://github.com/jiwookm/feather/releases). Maintainer instructions live in
[Releasing Feather](docs/RELEASING.md).

Installed releases can check, download, verify, install, and relaunch updates from **Feather →
Check for Updates…**. Update archives and the feed are signed with a dedicated Sparkle Ed25519 key;
its private half is stored only in GitHub Actions and the maintainer's login Keychain.

## What is implemented

- Create, reuse, rename for display, prioritize, backlog, and safely remove Git worktrees without changing the main checkout or Git branch names.
- Run Claude, Codex, or a plain shell in persistent tmux-backed tabs and split panes. Agent status remains visible in the sidebar while inactive terminal renderers are released.
- Browse, search, edit, diff, stage, commit, push, and review the current GitHub pull request through bounded native tools rather than a full IDE indexer.
- Hand a complete worktree state—including unpublished commits and nonignored working changes—to a configured SSH host, then return it transactionally to the unchanged local checkpoint.
- Preserve remote ownership and sessions across app restarts or temporary outages without pushing branches, forwarding credentials, or guessing that remote state was deleted.
- Check, cryptographically verify, install, and relaunch Feather updates from inside the app.
- Keep project, worktree presentation, selection, terminal, SSH profile, and remote-workspace metadata across launches.
- Stay native and performance-focused: SwiftUI/AppKit chrome, TextKit editing, Ghostty's Metal terminal renderer, no Electron, LSP, file watcher, or background project index.

## Platform

- Apple silicon Mac (`arm64`) only
- macOS 15 or newer
- Xcode command-line tools with Swift 6
- tmux (`brew install tmux`)
- ripgrep for repository content search (`brew install ripgrep`)
- Claude Code and/or Codex installed wherever your login shell can find them

Feather uses SwiftUI for low-frequency application chrome and AppKit for the terminal and TextKit hot paths. Its terminal renders directly into an `NSView` using Metal and CoreText. There is no Electron, web view, JavaScript runtime, file watcher, background repository scan, LSP, or project index.

## Build and run

```sh
brew install tmux ripgrep
./scripts/build-app.sh
open "dist/Feather Dev.app"
```

The packaging script always requests an arm64 release build. By default it creates an isolated
`Feather Dev.app` with its own app identity, saved state, and local/remote tmux namespace, so it can
run beside an installed release without sharing conversations. It applies an ad-hoc signature
unless `FEATHER_SIGN_IDENTITY` names a Developer ID Application identity. Run every release check
with:

```sh
./scripts/check-release.sh
```

The release check explicitly builds the production `dist/Feather.app`; direct production builds
can set `FEATHER_BUILD_VARIANT=production`.

For direct distribution, build with `FEATHER_BUILD_VARIANT=production` and
`FEATHER_SIGN_IDENTITY`, then set `FEATHER_NOTARY_PROFILE` to a `notarytool` keychain profile and
run `./scripts/notarize-app.sh`. This follows Apple's [Developer ID notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). GitHub Actions runs the same arm64 release checks on the standard `macos-15` Apple-silicon runner.

On first launch, choose **Add Project**, create or select a worktree, then open Claude, Codex, or a
plain terminal. The tab bar manages terminals; the sidebar context menu manages display names,
priority, backlog, reuse, remote execution, and removal.

For remote work, add and test an SSH profile in Settings. The host needs Git, tmux, tar, SHA-256
tooling, repository access, and the agent CLIs already authenticated. Use **Terminal → Run Workspace
Remotely…**, **Reconnect Remote Workspace**, and **Return Workspace to This Mac…**. Feather shows a
preflight before changing authority and keeps the local checkpoint unchanged until a return is
fully verified.

## Why the embedded renderer and tmux

The terminal engine provides a native macOS surface with a Metal renderer and AppKit host. This keeps the hot path native without embedding a standalone terminal application or introducing a cross-platform UI runtime.

tmux is not the renderer or the user interface. It is a small persistence layer. A direct PTY would save only a few megabytes while making tab hibernation and remote workspace reattachment substantially more complex. On the target M-series Mac, an idle private server measured roughly 3.7 MB RSS with one terminal, 3.9 MB with ten, and 4.1 MB with twenty; idle CPU remained effectively zero. Scrollback is bounded to 10,000 lines because history—not the server itself—is the meaningful growth vector.

See [Architecture](docs/ARCHITECTURE.md) for the design and remote workspace boundary.
Performance budgets and the local measurement command live in
[Performance Contract](docs/PERFORMANCE.md).
Current hosting choices and the AWS/Azure credit strategy are in
[Remote Hosting](docs/REMOTE-HOSTING.md).

## Scope

Feather intentionally has no general IDE subsystem, project-wide indexing, always-on file watcher,
LSP, syntax-engine dependency, agent-specific runtime wrapper, arbitrary terminal themes, plugin
system, cloud control plane, or synchronization service. Its small in-tree lexical colorizer is capped and operates only on the
explicitly opened file or diff; hiding the inspector or editor leaves no scan, watcher, or
background task alive. Agent sessions remain ordinary terminal programs.

The renderer is Ghostty's pinned first-party native library. Feather owns the smallest Swift/AppKit
boundary needed to host its Metal surface; no third-party Swift terminal wrapper is shipped. See
[Third-party notices](Resources/ThirdPartyNotices.txt).

## License

Feather is available under the [MIT License](LICENSE).
