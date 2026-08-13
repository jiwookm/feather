import Testing

@testable import FeatherCore

struct ProcessResourcesTests {
  @Test
  func parsesAndAttributesOnlyFeatherProcessTree() {
    let rows = ProcessResourceParser.parse(
      """
       100 1 50000 1.5 /Applications/Feather.app/Contents/MacOS/Feather
       101 100 1000 0.1 /bin/ps -axo pid=,ppid=,rss=,pcpu=,command=
       200 1 4000 0.0 /opt/homebrew/bin/tmux -f /Users/a/Library/Application Support/Feather/tmux.conf
       201 200 3000 0.2 -zsh
       202 201 120000 8.4 /Users/a/.local/bin/claude --dangerously-skip-permissions
       203 200 90000 4.1 /opt/homebrew/bin/codex
       999 1 70000 2.0 /opt/homebrew/bin/codex unrelated
      """
    )

    let summary = ProcessResourceParser.summarize(rows, applicationPID: 100)

    #expect(summary.first { $0.kind == .feather }?.residentKiB == 50_000)
    #expect(summary.first { $0.kind == .tmux }?.residentKiB == 4_000)
    #expect(summary.first { $0.kind == .child }?.residentKiB == 3_000)
    #expect(summary.first { $0.kind == .claude }?.residentKiB == 120_000)
    #expect(summary.first { $0.kind == .codex }?.residentKiB == 90_000)
    #expect(summary.map(\.residentKiB).reduce(0, +) == 267_000)
  }
}
