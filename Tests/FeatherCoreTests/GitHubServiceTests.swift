import Foundation
import Testing

@testable import FeatherCore

struct GitHubServiceTests {
  @Test
  func loadsTheCurrentPullRequestAndChecks() async throws {
    let fixture = try makeExecutable(
      """
      #!/bin/zsh
      if [[ "$2" == "view" ]]; then
        print -n '{"number":42,"title":"Lean inspector","state":"OPEN","isDraft":false,"url":"https://github.com/example/repo/pull/42","reviewDecision":"APPROVED","headRefName":"alpha","baseRefName":"main","author":{"login":"octocat"}}'
      else
        print -n '[{"name":"test","state":"SUCCESS","bucket":"pass","link":"https://github.com/example/repo/actions/1","workflow":"CI"}]'
      fi
      """
    )
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

    let snapshot = try await GitHubService(executable: fixture.path).currentPullRequest(
      worktreePath: fixture.deletingLastPathComponent().path
    )

    #expect(snapshot.pullRequest.number == 42)
    #expect(snapshot.pullRequest.reviewDecision == "APPROVED")
    #expect(snapshot.checks.first?.bucket == "pass")
  }

  @Test
  func distinguishesABranchWithoutAPullRequest() async throws {
    let fixture = try makeExecutable(
      """
      #!/bin/zsh
      print -u2 'no pull requests found for branch "alpha"'
      exit 1
      """
    )
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

    await #expect(throws: GitHubServiceError.noPullRequest) {
      try await GitHubService(executable: fixture.path).currentPullRequest(
        worktreePath: fixture.deletingLastPathComponent().path
      )
    }
  }

  private func makeExecutable(_ contents: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-gh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("gh")
    try Data(contents.utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    return executable
  }
}
