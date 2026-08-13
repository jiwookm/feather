import Foundation
import Testing

@testable import FeatherCore

struct GitWorktreeParserTests {
  @Test
  func parsesPorcelainZRecords() throws {
    let input = nulSeparated([
      "worktree /Users/example/repo",
      "HEAD 0123456789abcdef",
      "branch refs/heads/main",
      "",
      "worktree /Users/example/repo-feature",
      "HEAD fedcba9876543210",
      "detached",
      "locked reason",
      "",
    ])

    let worktrees = try GitWorktreeParser.parse(input)

    #expect(worktrees.count == 2)
    #expect(worktrees[0].path == "/Users/example/repo")
    #expect(worktrees[0].branchDisplayName == "main")
    #expect(worktrees[1].path == "/Users/example/repo-feature")
    #expect(worktrees[1].isDetached)
    #expect(worktrees[1].isLocked)
  }

  @Test
  func rejectsAFieldBeforeAWorktree() {
    #expect(throws: FeatherError.malformedGitOutput) {
      try GitWorktreeParser.parse(nulSeparated(["HEAD abc"]))
    }
  }

  private func nulSeparated(_ fields: [String]) -> Data {
    fields.reduce(into: Data()) { data, field in
      data.append(contentsOf: field.utf8)
      data.append(0)
    }
  }
}
