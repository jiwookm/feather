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
        print -n '{"number":42,"title":"Lean inspector","state":"OPEN","isDraft":false,"url":"https://github.com/example/repo/pull/42","reviewDecision":"APPROVED","headRefName":"alpha","baseRefName":"main","headRefOid":"abc123","mergeStateStatus":"CLEAN","author":{"login":"octocat"}}'
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
    #expect(snapshot.pullRequest.headRefOid == "abc123")
    #expect(snapshot.pullRequest.mergeStateStatus == "CLEAN")
    #expect(snapshot.checks.first?.bucket == "pass")
    #expect(snapshot.mergeBlockReason == nil)
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

  @Test
  func blocksMergeUntilThePullRequestIsSafe() {
    let ready = GitHubPullRequestSnapshot(
      pullRequest: pullRequest(),
      checks: [check(bucket: "pass"), check(name: "Optional", bucket: "skipping")]
    )
    #expect(ready.mergeBlockReason == nil)

    let pending = GitHubPullRequestSnapshot(
      pullRequest: pullRequest(),
      checks: [check(bucket: "pending")]
    )
    #expect(pending.mergeBlockReason == "Wait for pending checks to finish.")

    let failing = GitHubPullRequestSnapshot(
      pullRequest: pullRequest(),
      checks: [check(bucket: "fail")]
    )
    #expect(failing.mergeBlockReason == "Resolve failing checks before merging.")

    let conflicted = GitHubPullRequestSnapshot(
      pullRequest: pullRequest(mergeStateStatus: "DIRTY"),
      checks: [check(bucket: "pass")]
    )
    #expect(conflicted.mergeBlockReason == "Resolve merge conflicts before merging.")

    let draft = GitHubPullRequestSnapshot(
      pullRequest: pullRequest(isDraft: true),
      checks: [check(bucket: "pass")]
    )
    #expect(draft.mergeBlockReason == "Mark the pull request ready before merging.")
  }

  @Test
  func hidesBlankAndRedundantCheckWorkflowNames() {
    #expect(check(workflow: nil).distinctWorkflowName == nil)
    #expect(check(workflow: "  \n").distinctWorkflowName == nil)
    #expect(check(name: "Vercel", workflow: "vercel").distinctWorkflowName == nil)
    #expect(check(name: "Build", workflow: " CI ").distinctWorkflowName == "CI")
  }

  @Test
  func mergePinsTheVerifiedHeadCommitAndUsesSquash() async throws {
    let fixture = try makeExecutable(
      """
      #!/bin/zsh
      print -rl -- "$@" > "${0:h}/arguments"
      print -n -- "$GH_PROMPT_DISABLED" > "${0:h}/prompt-disabled"
      pwd > "${0:h}/working-directory"
      """
    )
    let root = fixture.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: root) }

    try await GitHubService(executable: fixture.path).mergePullRequest(
      pullRequest(),
      worktreePath: root.path
    )

    let arguments = try String(
      contentsOf: root.appendingPathComponent("arguments"),
      encoding: .utf8
    ).split(separator: "\n").map(String.init)
    #expect(
      arguments
        == ["pr", "merge", "42", "--squash", "--match-head-commit", "abc123"]
    )
    #expect(
      try String(
        contentsOf: root.appendingPathComponent("prompt-disabled"),
        encoding: .utf8
      ) == "1"
    )
    #expect(
      URL(
        fileURLWithPath: try String(
          contentsOf: root.appendingPathComponent("working-directory"),
          encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
      ).resolvingSymlinksInPath()
        == root.resolvingSymlinksInPath()
    )
  }

  private func pullRequest(
    isDraft: Bool = false,
    mergeStateStatus: String = "CLEAN"
  ) -> GitHubPullRequest {
    GitHubPullRequest(
      number: 42,
      title: "Lean inspector",
      state: "OPEN",
      isDraft: isDraft,
      url: URL(string: "https://github.com/example/repo/pull/42")!,
      reviewDecision: "APPROVED",
      headRefName: "alpha",
      baseRefName: "main",
      headRefOid: "abc123",
      mergeStateStatus: mergeStateStatus,
      author: GitHubPullRequest.Author(login: "octocat")
    )
  }

  private func check(
    name: String = "test",
    bucket: String = "pass",
    workflow: String? = "CI"
  ) -> GitHubCheck {
    GitHubCheck(
      name: name,
      state: bucket.uppercased(),
      bucket: bucket,
      link: nil,
      workflow: workflow
    )
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
