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

## What is implemented

- Add Git projects with their `origin` visible in the sidebar. The project header represents the main checkout, and only worktrees Feather explicitly created appear beneath it. Worktrees created outside Feather remain available from the project's three-dot menu.
- Before creating a worktree, run `git fetch --prune origin` and branch from `origin/HEAD` (then `origin/main` or `origin/master`) without changing the user's main checkout. Local-only projects remain supported.
- Create one-click worktrees under `~/Developer/Worktrees/<repository>/<name>`, assigning `alpha`, `beta`, and subsequent collision-free names automatically.
- Exclude the dedicated worktree root from Spotlight before materializing checkouts, avoiding metadata-import spikes on large repositories.
- Insert and select a sidebar progress row immediately while Git fetches and prepares a new checkout, then replace it with the finished worktree without blocking navigation elsewhere.
- Return finished Feather worktrees to an explicit local pool, then reuse the checkout on the next one-click creation. Pooling is allowed only after all terminals close, the tree is clean, and its commits are merged into the fetched default branch; ignored dependency and build caches stay warm.
- On a brand-new worktree, APFS-clone the main checkout's ignored `node_modules` only when both checkouts have byte-identical package-manager lockfiles. The clone is isolated and copy-on-write; Feather never shares it by symlink and never falls back to a large ordinary copy.
- Create a worktree first, then start each terminal as Claude, Codex, or a plain shell. Agent choices launch immediately with their explicit permission-bypass flags inside the worktree's persistent tmux session.
- Refuse to remove the main checkout, a dirty worktree, or a worktree with managed terminals.
- Remove a project from Feather while choosing whether to keep its checkouts or delete only the clean worktrees Feather recorded as its own. Git branches are retained.
- Create multiple terminal tabs per worktree. Each tab is one isolated session in a single private tmux server.
- Split the current tab right or down using tmux panes with a neutral native divider, without adding another renderer or persistence layer.
- Detach and release inactive Metal terminal surfaces while tmux keeps their processes alive.
- Toggle a native right inspector with Command-E. Files enumerates only the selected or explicitly expanded directory; Source Control offers bounded status/diff, collapsible change groups, per-file and aggregate line statistics, stage, unstage, discard, commit, and push. Its Branch Review scope compares the whole checkout with a selected local or origin-tracking branch at their merge-base, then loads only the file patch you open. GitHub loads only the current branch's pull request and checks through the authenticated `gh` CLI. Usage samples Feather, tmux, Claude, and Codex CPU/RSS only while that tab is visible.
- Press Command-P for filename Quick Open. It runs one cancellable, bounded `git ls-files`, keeps candidates only while the picker is open, and performs fuzzy matching off the main actor without creating an index or watcher.
- Press Command-Shift-F for literal repository text search. Feather invokes at most one cancellable, two-thread ripgrep process, caps file size, runtime, output, and displayed matches, and releases every result when the picker closes.
- Open a file from Files or Quick Open in a central native TextKit editor with line numbers and bounded Night Owl-style lexical coloring, or open a changed file directly into an in-app unified/split diff and switch to its working copy. Lightweight document tabs retain only paths and diff descriptors; exactly one file buffer and at most one parsed diff remain loaded. Review includes old/new line gutters, change statistics, word wrap, and ignore-whitespace. Editing supports undo, find, word wrap, explicit save, and unsaved-change prompts. Reads are UTF-8-only and capped at 2 MB; saves refuse to overwrite a file that an agent changed after it was opened.
- Poll one bounded tmux pane snapshot every two seconds locally and every six seconds for connected remote workspaces. The current command and pane title identify Claude, Codex, working, waiting, shell, and exited sessions even after the command launched in a tab changes. A completed response remains marked until opened and is not marked again until that agent works again; state is never written to disk.
- Make a named-branch worktree remote-first through a named SSH profile, including unpublished commits and staged, unstaged, and nonignored untracked work. Feather never pushes: it sends unpublished Git objects in a bundle, keeps index and working-copy patches distinct, and copies only an explicit NUL-delimited untracked manifest after rejecting unsafe or likely credential paths. A bounded preflight summarizes the transfer; the remote checkout must reproduce every Git-state hash before Feather atomically writes ownership markers, starts its private tmux workspace, and changes execution authority. Saved ownership, handoff, terminal, and SSH metadata survive app restarts; a dropped SSH attachment never ends or recreates its tmux session. Unreachable hosts stay offline and missing sessions stay visibly exited without being recreated. Feather does not forward an SSH agent, copy ignored caches, provision infrastructure, or store credentials.
- Return a remote workspace to its unchanged local checkpoint through a second bounded, transactional transfer. Feather verifies the captured result in an isolated clone, applies it locally with a rollback checkpoint, and ends only its recorded remote sessions after local verification succeeds. The owned remote checkout remains recorded and intact until a separate destructive cleanup confirmation rechecks its central marker, checkout marker, and original handoff manifest. Offline, ownership-mismatched, returned, and locally unlisted records stay visible; Feather never infers that a remote resource was deleted.
- Keep Files, Changes, GitHub review, Quick Open, and repository search off while a remote workspace is authoritative, rather than presenting or modifying its local checkpoint as though it were current. Resource usage remains available.
- Show a small, natively cached GitHub owner avatar for each GitHub project, with an SF Symbol fallback and no icon framework.
- Persist repository, selection, and terminal metadata across launches.
- Offer only Light and Dark terminal palettes, plus a System preference that selects between them. Dark mode uses the established chrome colors, a `#0d0d0d` Night Owl terminal, Geist app typography, and JetBrains Mono terminal text.

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

On first launch, choose **Add Project**, then use the project's **New Worktree** action. A new worktree opens with no terminal; choose Claude, Codex, or Terminal from its empty state. In any selected worktree, clicking the tab-bar `+` or pressing Command-T opens the same three choices.

Use Control-Tab to move to the next terminal in the selected worktree, Control-Shift-Tab to move backward, Command-D to split right, Command-Shift-D to split down, Command-S to toggle the project sidebar, Command-E to toggle the inspector, Command-P for Quick Open, and Command-Shift-F for repository search. Command-Shift-S saves an open file. Command-W closes the selected document tab first, otherwise the active pane after confirmation when the terminal tab is split; once one pane remains, it closes that terminal tab/session.

To use a remote workspace, add and select a named SSH profile in Settings, then test the connection. The host must already have Git, tmux, tar, SHA-256 tooling, repository access, and the desired agent CLI authentication. Close the worktree's terminals and open files, then choose **Terminal → Run Workspace Remotely…**. The named branch needs a base commit available from `origin`, but its later commits and working changes do not need to be pushed. Review the bounded preflight summary before transferring. Feather leaves the local checkout untouched, verifies its ownership marker and saved tmux sessions before attaching after a restart, and keeps it authoritative if staging or verification fails. Use **Reconnect Remote Workspace** for an explicit retry after the host was offline. If a saved session really exited, Feather leaves it visibly exited and never creates a replacement under the old tab.

Choose **Terminal → Return Workspace to This Mac…** after closing local file tabs. Feather refuses if the local checkpoint changed or the returned state would expose or overwrite ignored local data, captures and verifies the complete nonignored remote Git state, restores the original local checkpoint if application fails, and keeps the remote checkout even after a successful return. Use **Clean Up Remote Copy…** only after reviewing its separate destructive confirmation; any recorded session that appeared after preflight forces a fresh confirmation. A missing local checkout remains listed under **Remote Records** rather than causing Feather to forget or delete the remote resource.

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
