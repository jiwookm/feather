# Performance Contract

Feather treats idle cost as a product constraint. Measurements are taken on a release arm64 build,
with the same window size and selected terminal before and after a feature change. The local helper
script records the bundle, process, private tmux, and optional Git/search baselines without launching
the app or changing repository state:

```sh
./scripts/performance-report.sh ~/Developer/Worktrees/example/alpha
```

## Current reference

The initial right-inspector baseline was captured on an M1 Pro Mac with 16 GB RAM, macOS 26.5.2,
and a 19,608-file worktree:

- Release app bundle: 15 MB; arm64 only.
- Feather with one visible terminal: approximately 116 MB RSS, with idle CPU normally 0–1.3%.
- Visible tmux client: approximately 8 MB RSS.
- Private tmux server: approximately 3.5 MB RSS.
- Warm `git status --porcelain=v2 --branch --untracked-files=all`: 126.5 ms median over ten runs.

These figures are a development reference, not universal promises. Acceptance testing should also
run on a base M1 Mac with 8 GB RAM before release.

The completed native-inspector checkpoint on the same machine measures:

- Release app bundle: 16.0 MB; arm64 only.
- Feather with one visible terminal and the inspector hidden: 110.4 MB RSS and 0.6% sampled CPU.
- Warm Git status on the same 19,608-file worktree: 151.3 ms median and 169.1 ms p95 over 20
  measured runs after an unmeasured warm-up.

The inspector therefore remains below the original idle-memory reference while the Git path stays
inside its 250 ms p95 budget. Run the helper again for every feature that can affect startup, idle
work, filesystem access, Git, or rendering.

The native editor/diff checkpoint on the same machine measures:

- Current release app bundle: 17,156 KiB (16.8 MiB); arm64 only. The bounded Changes statistics
  and UI add 120 KiB over the 17,036 KiB editor/diff checkpoint; test and documentation code are
  not included in the app bundle.
- Freshly opened with the Files inspector visible and no terminal surface: 105.5 MB RSS. After the
  initial UI work settled, sampled idle CPU was 0.0–0.2%.
- Warm Git status on the same 19,608-file worktree: 135.8 ms median and 151.7 ms p95 over 20
  measured runs after an unmeasured warm-up.

Editor and diff surfaces have offscreen AppKit regression tests that verify actual glyph rendering
for the editor and both diff layouts. These tests prevent an invisible TextKit layer from passing
data-only tests without adding code, timers, or diagnostics to the release process.

The titlebar-alignment and inspector-hit-target pass is event-driven. It adds no layout loop, timer,
polling task, watcher, or idle work.

The native Changes-summary checkpoint keeps the status-only path for a clean or
untracked-only worktree. When tracked changes exist, it adds only the relevant staged and/or
unstaged `git diff --numstat` command; both run concurrently when both are needed. A conservative
forced three-command measurement on the same clean 19,608-file checkout completed in 172.1 ms
median and 177.3 ms p95 over 20 runs. The accompanying status-only sample was 137.7 ms median and
143.9 ms p95. Both remain well inside their budgets, and there is still no recurring refresh.

The Quick Open, metadata-tab, branch-review, and on-demand-usage checkpoint was captured on the
same 19,608-file M1 Pro worktree with 20 warm runs:

- Release app bundle: 18,060 KiB (17.6 MiB), arm64 only. The four native features add 904 KiB over
  the previous 17,156 KiB checkpoint, remaining below the 1 MiB payload-review threshold.
- Quick Open's bounded tracked/untracked filename enumeration: 111.6 ms median and 113.5 ms p95.
  Matching runs in a cancellable worker; closing the picker cancels it and releases all candidates.
- Full Branch Review refresh against `origin/main`, including merge-base resolution, repository
  `--numstat`, and status/untracked discovery: 170.2 ms median and 173.0 ms p95.
- One on-demand `ps` process-tree snapshot: 33.6 ms median and 35.2 ms p95. Sampling occurs every
  two seconds only while Usage is visible and is cancelled when the tab disappears.
- The existing Changes refresh measured 163.4 ms median and 183.0 ms p95 in the same run; Git
  status alone measured 129.9 ms median and 146.1 ms p95.

Live post-feature UI RSS was intentionally not sampled during this checkpoint because the active
desktop app was not relaunched. Repeat the fresh-launch measurement on the M1 reference before a
release candidate; command latency, release size, architecture, tests, and hidden-work lifecycles
were verified without controlling the user's desktop.

The repository-search, terminal-state, release, and clean-SSH-handoff checkpoint was captured on
2026-08-13 on the same M1 Pro with 16 GB RAM. This development checkout contains 65 tracked files;
the before and after command samples each used 20 warm runs:

- The arm64 release bundle moved from 19,284 KiB to 19,992 KiB, a 708 KiB increase that remains
  below the 1 MiB payload-review threshold.
- Git status moved from 20.1 ms median / 21.5 ms p95 to 19.2 ms / 21.0 ms. Changes refresh moved
  from 33.2 ms / 48.0 ms to 36.1 ms / 40.9 ms; Quick Open moved from 19.0 ms / 21.4 ms to
  18.5 ms / 20.9 ms; Branch Review moved from 43.2 ms / 51.5 ms to 45.7 ms / 52.4 ms.
- A representative bounded literal repository search measured 13.5 ms median and 14.7 ms p95.
  This small checkout validates the command path but does not replace the required 20k-file release
  candidate measurement.
- The app was not running in either sample, so no live UI RSS comparison is claimed. Repository
  search owns a subprocess only while its overlay has a two-or-more-character query. Runtime state
  performs one bounded all-session tmux snapshot every two seconds locally and every six seconds
  for connected remote workspaces. Release tooling does no background work.
- A 2026-08-18 sample against ten live local sessions launched the snapshot command 100 times
  back-to-back: 38.6 ms median, 53.3 ms p95, and 73.0 ms maximum including the benchmark shell's
  process-launch overhead. The ordinary two-second interval does not run them back-to-back.

## Feature budgets

- A hidden inspector performs no timers, filesystem reads, Git/GitHub commands, network requests,
  recursive scans, or file watching. Its steady-state RSS increase should stay under 2 MB; 5 MB is a
  rejection threshold.
- Command-E should present or hide the inspector in under 50 ms at p95.
- Expanding one directory should finish in under 50 ms at p95 for ordinary folders. Only that
  directory is enumerated; no descendant is read until expanded.
- Git status should finish in under 250 ms at p95 on the reference 20k-file checkout. Results are
  bounded and superseded requests are cancelled.
- A complete Changes refresh (status, then staged and unstaged line statistics in parallel) should
  finish in under 300 ms at p95 on the same checkout. It runs only when Changes is visible and is
  cancelled when that surface closes.
- GitHub state is loaded only while its tab is visible and only by explicit refresh or selection. It
  has a finite timeout and no polling loop.
- The file editor reads only the selected UTF-8 file, rejects content over 2 MB, and owns no watcher,
  autosave timer, syntax-engine dependency, or project cache. Its in-tree lexical coloring stops at
  768 KiB; larger files remain plain and editable. Closing it releases both its text and the opening
  revision bytes.
- Diff input is capped at 1 MB and parsed off the main actor. Syntax coloring shares the 768 KiB
  aggregate cap and stops at 2,000 patch lines so many tiny hunks cannot amplify regex setup work.
  Split mode creates its second TextKit layout only while selected and never runs a
  scroll-synchronization timer.
- A feature that adds more than 1 MB to the compressed app payload needs explicit justification.
- Quick Open filename enumeration should remain under 150 ms p95 on the reference 20k-file
  checkout. Its paths and match task must be gone when the picker closes.
- Repository search should remain under 250 ms p95 for a common literal on the reference 20k-file
  checkout. It is limited to two ripgrep threads, a 2 MB file ceiling, a 2 MB output ceiling, 200
  displayed matches, and ten seconds even on an adversarial tree; dismissal cancels the child.
- Branch Review headers should remain under 250 ms p95 on the reference checkout. File bodies load
  only on selection and keep the existing 1 MB patch ceiling.
- Resource sampling should remain under 50 ms p95 and run only while Usage is visible; no snapshot,
  peak, or timer survives tab dismissal.
- The all-session tmux runtime snapshot should remain under 75 ms p95 locally. Exactly one polling
  task may exist while recorded terminals exist; it must stop when the final terminal is removed.

Measure cold and warm behavior separately when it matters. Do not hide latency in startup or replace
it with perpetual background work.
