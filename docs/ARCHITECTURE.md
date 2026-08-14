# Architecture

## Runtime shape

```text
SwiftUI sidebar and tab chrome
             |
             v
AppModel ----+---- GitService actor -------- /usr/bin/git
    |        +---- RepositorySearch actor -- ripgrep (on demand)
    |
    +------------- TerminalRegistry (one visible surface)
                         |
                         v
              native terminal AppKit NSView
                         |
                         v
            local or SSH private tmux server
                  one session per tab
                         |
                         v
                    /bin/zsh -l
                  (claude / codex)
```

The application model is main-actor isolated. Git, search, SSH, and tmux operations run through actors so process launches never become shared mutable UI state. Repository discovery is explicit and refresh-driven; there is no filesystem scan or status polling loop.

The optional right inspector is absent from the SwiftUI tree while hidden. Its Files tab reads one directory at a time and retains only expanded listings, capped at 2,000 entries each. Selecting a UTF-8 file swaps the live terminal surface for one transient TextKit editor while tmux retains the process; files are capped at 2 MB, saved explicitly, and compared with their opening bytes before an atomic write. Document tabs retain only UUID/path/diff metadata for inactive files, so there is still one editor buffer, one opening revision, and at most one parsed patch. Command-P creates a temporary Quick Open model, obtains at most 50,000 tracked/untracked paths from one bounded `git ls-files`, performs matching in a cancellable worker, and releases the list when dismissed. Command-Shift-F creates a separate temporary search model and runs literal smart-case ripgrep with two threads, a 2 MB per-file ceiling, a ten-second timeout, a 2 MB output ceiling, and 200 displayed lines. It has no index, cache, watcher, or state after dismissal.

Source Control uses a cancellable process runner with output/time limits, caps status and branch review at 5,000 files, and caps each opened patch at 1 MB. Working-tree line statistics invoke only the staged and/or unstaged `--numstat` command relevant to visible tracked changes, in parallel when both are needed. Branch Review resolves a selected local or origin-tracking ref, finds its merge-base with `HEAD`, and obtains repository-wide path/stat headers plus untracked paths; only the selected file body is requested and parsed. It never fetches implicitly. GitHub invokes the installed `gh` binary only while that tab is visible, for the current branch's PR and checks. Usage invokes one bounded `ps` snapshot every two seconds only while visible, attributes the Feather/private-tmux process tree, and releases its snapshot on disappearance. No hidden tab or document owns a watcher, timer, index, database, autosave loop, or background refresh loop.

The editor uses one native `NSTextView`, a narrow event-driven line-number gutter, and a small in-tree lexical
colorizer with cached regular expressions. Coloring is limited to 768 KiB; larger accepted files
remain fully editable as plain monospaced text. The diff path parses unified patches off the main
actor, then renders either one TextKit surface or two vertically synchronized surfaces. Syntax color
uses the same aggregate cap, split rows are paired by deletion/addition blocks, and Git remains the
source of truth for whitespace filtering. No syntax tree, language server, worker pool, or file cache
survives the open document.

Each terminal tab has a stable UUID and derived tmux session name. Only the selected tab owns a terminal rendering session and Metal-backed `NSView`. Switching tabs releases that surface and its tmux client; the private tmux server retains the shell, child agent, screen state, and bounded history. Re-selecting the tab attaches a fresh surface to the same session.

Runtime badges contain only ephemeral shell, running, attention, or exited state. A single cancellable `tmux wait-for` client blocks until tmux signals an app-launched agent completion, pane lifecycle, or monitored bell event, then Feather reads one bounded active-pane snapshot for all local sessions. The visible Ghostty surface also forwards progress, command-finished, bell, and desktop-notification actions. There is no recurring status query, and Feather deliberately makes no claim about an agent's semantic reasoning state.

Split Right and Split Down create tmux panes inside that same tab session. The renderer still owns one native surface, and tmux remains the only pane layout and process owner. Command-W closes the exact active pane while multiple panes exist and never removes the final pane; at one pane it follows the existing whole-tab confirmation path.

When AppKit reports a backing-scale change, Feather updates the renderer's content scale and pixel dimensions together. This keeps cell metrics stable when the window moves between Retina and non-Retina displays.

Feather starts tmux with a private socket and app-owned configuration. It neither reads nor mutates the user's normal tmux configuration. The child is a login zsh, so command availability still follows the user's normal shell setup.

## Terminal-engine decision

The terminal engine is pinned to a known revision and embedded through its supported native macOS
boundary. It provides an AppKit view backed by Metal and CoreText, so Feather does not need to own
a parser, glyph atlas, renderer, accessibility bridge, or terminal compatibility layer. The exact
third-party component and license are recorded in the bundled notices.

## Why managed tmux instead of a direct PTY

A direct PTY backend removes the tmux server and its small screen model. It does not remove the shell or the agent process, which dominate memory once Claude Code or Codex is running. It would also require Feather to retain every terminal emulator surface or build its own scrollback/state serialization.

One private tmux server amortizes overhead across all tabs and gives three useful invariants:

1. Closing or hibernating a renderer never stops the agent.
2. Relaunching Feather can reattach by stable session ID.
3. The SSH backend uses the same session lifecycle on Linux without a second protocol.

The history limit is intentionally 10,000 lines. Testing showed a server remained near 4 MB RSS through twenty idle sessions, while an artificial 100,000-line history increased it to roughly 21 MB.

## Worktree safety

Each project stores its main checkout and `origin` URL. The project header represents that checkout, while only worktrees Feather explicitly created and persisted appear beneath it. Other linked checkouts remain accessible from the project menu, but path naming is never treated as proof of ownership.

New checkouts are centralized under `~/Developer/Worktrees`. Before any checkout is materialized, Feather creates `.metadata_never_index` at that dedicated root so macOS does not spend resources indexing duplicate repository files. Feather assigns collision-free names from `alpha` through `omega`, then continues with numeric generations. Creation fetches and prunes `origin` without pulling or changing the main checkout. The base selection order is `origin/HEAD`, `origin/main`, `origin/master`, local `main`, local `master`, then the current branch or `HEAD`.

Worktree creation has one ephemeral, non-persisted UI record because creation is serialized. The record appears and is selected before Git work begins, can be left while the user navigates elsewhere, and is replaced atomically with the owned worktree record when creation succeeds. Failure removes the placeholder and returns its selection to the project checkout.

Removal is deliberately conservative:

- the registered main checkout is never removable;
- worktrees not explicitly recorded as Feather-created are never removable;
- every Feather terminal for the worktree must be closed;
- `git status --porcelain -z --untracked-files=all` must be empty;
- Git performs the removal, and the branch is retained.

Feather-owned worktrees can instead be returned to a small persisted pool. An `Active` worktree becomes `Available` only when it has no Feather terminals, its tracked and untracked status is clean, and its HEAD is an ancestor of the freshly fetched default base. Feather then resets tracked files to that base while preserving ignored dependency and build-cache directories. New Worktree claims a safe available checkout before allocating the next Greek-named checkout; an available tree changed outside Feather is skipped rather than cleaned implicitly.

For a newly allocated checkout, Feather performs one optional macOS-native warm-dependency step. If the main checkout has a real `node_modules` directory, Git says that path is ignored in the new worktree, and every present package-manager lockfile matches byte-for-byte, `/bin/cp -R -c` creates an APFS copy-on-write clone. The destination behaves as an independent tree, so package-manager or agent writes cannot poison the source checkout. A cross-volume or unsupported clone is removed and skipped; Feather never degrades this optimization into an expensive ordinary copy or a shared symlink.

Removing an entire project always asks whether its Feather-created worktrees should be kept or deleted. Both choices explicitly end that project's terminal sessions; deletion preflights every owned worktree before removing any of them.

## Remote workspace boundary

Remote execution is not live process migration or continuous synchronization. A macOS process cannot be transplanted into a Linux VPS. The implemented boundary is a bounded, transactional worktree checkpoint and restart:

1. Validate a selected named OpenSSH profile containing only a display name, host alias, port, and absolute root. Feather stores no password, private key, cloud token, or agent credential.
2. Require a named branch and resolve a commit already available from `origin` as its base. A branch advertised by `origin` must be an ancestor of local `HEAD`; a local-only branch may use the remote default branch's merge-base. Feather never pushes as part of handoff.
3. Capture a stable local fingerprint: `HEAD`, base and advertised commits, normalized status, separate binary/full-index staged and unstaged patches, plus an explicit NUL-delimited list of nonignored untracked files. Unpublished objects travel in a Git bundle. Regular files and symlinks are hashed individually; modes, binary data, deletions, and rename-equivalent index state are preserved. `.git` paths, ignored caches, unsafe path components, special files, and common credential paths are excluded before packaging.
4. Enforce fixed limits on patches, metadata, unpublished objects, individual and aggregate untracked bytes, file count, process output, and duration. The confirmation alert reports commit/path counts and total transfer size. A second capture must match that accepted preflight before transfer can proceed.
5. Require all terminals and open documents for the worktree to be closed before changing authority. Over non-interactive system SSH with agent forwarding disabled, stream the archive into token-owned staging paths, verify its hashes, clone `origin`, unbundle commits, apply index and worktree state separately, materialize only the untracked manifest, and regenerate every normalized Git-state hash remotely.
6. Only after complete remote verification and another unchanged local fingerprint may Feather atomically move staging to its final checkout, write central and checkout-bound ownership markers, and start a bootstrap session in the private tmux server. A final local fingerprint precedes the returned authority record. Every failure path uses the unique ownership token to remove only this operation's staging, checkout, markers, and bootstrap session; cleanup that cannot be verified is reported explicitly. The local worktree and local tmux namespace are never mutated.
7. Persist one remote-workspace record, its verified handoff manifest, and ownership token keyed by repository and local worktree path. Every later Claude, Codex, or shell terminal resolves through that record, so sibling tabs cannot disagree about execution location.
8. On app restart, verify the remote checkout, both ownership markers, and the recorded tmux sessions before attaching a native surface through `/usr/bin/ssh -tt`. Attachment uses `tmux attach-session`, never a create-or-attach command, so a missing session remains visibly `exited` instead of silently starting a replacement process. An unexpected SSH child exit triggers one bounded ownership/session reconciliation: a surviving tmux session becomes `offline` until explicit reconnect, while a genuinely missing session becomes `exited`. Startup, terminal selection, explicit reconnect, and that attachment event are the only remote snapshot triggers; there is no idle polling loop.
9. Do not expose the local Files, Changes, GitHub review, Quick Open, or repository-search paths while remote authority is active; the local checkout is a checkpoint, not a current view of remote state.
10. Legacy snapshots that stored SSH metadata on one terminal migrate to one worktree record while local-only and clean published handoffs retain their existing behavior.

This boundary intentionally omits automatic provisioning, continuous or bidirectional synchronization, remote checkout deletion/return, agent forwarding, and provider-session copying.
