import Foundation

public struct GitHubPullRequest: Codable, Equatable, Sendable {
  public struct Author: Codable, Equatable, Sendable {
    public let login: String
  }

  public let number: Int
  public let title: String
  public let state: String
  public let isDraft: Bool
  public let url: URL
  public let reviewDecision: String?
  public let headRefName: String
  public let baseRefName: String
  public let headRefOid: String?
  public let mergeStateStatus: String?
  public let author: Author?
}

public struct GitHubCheck: Codable, Equatable, Identifiable, Sendable {
  public var id: String { "\(workflow ?? ""):\(name):\(link ?? "")" }
  public var distinctWorkflowName: String? {
    guard let workflow else { return nil }
    let normalized = workflow.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized.localizedCaseInsensitiveCompare(normalizedName) != .orderedSame
    else { return nil }
    return normalized
  }
  public let name: String
  public let state: String
  public let bucket: String
  public let link: String?
  public let workflow: String?
}

public struct GitHubPullRequestSnapshot: Equatable, Sendable {
  public let pullRequest: GitHubPullRequest
  public let checks: [GitHubCheck]

  public init(pullRequest: GitHubPullRequest, checks: [GitHubCheck]) {
    self.pullRequest = pullRequest
    self.checks = checks
  }

  public var mergeBlockReason: String? {
    guard pullRequest.state.uppercased() == "OPEN" else {
      return "Only an open pull request can be merged."
    }
    guard !pullRequest.isDraft else { return "Mark the pull request ready before merging." }
    guard pullRequest.headRefOid?.isEmpty == false else {
      return "Refresh to verify the pull request head commit."
    }
    if pullRequest.reviewDecision?.uppercased() == "CHANGES_REQUESTED" {
      return "Requested changes must be resolved before merging."
    }
    if checks.contains(where: { $0.bucket.lowercased() == "pending" }) {
      return "Wait for pending checks to finish."
    }
    if checks.contains(where: {
      ["fail", "cancel"].contains($0.bucket.lowercased())
    }) {
      return "Resolve failing checks before merging."
    }
    switch pullRequest.mergeStateStatus?.uppercased() {
    case "BLOCKED":
      return "GitHub reports that this pull request is blocked."
    case "BEHIND":
      return "Update the branch before merging."
    case "DIRTY":
      return "Resolve merge conflicts before merging."
    case "UNKNOWN":
      return "GitHub is still calculating mergeability."
    default:
      return nil
    }
  }
}

public enum GitHubServiceError: LocalizedError, Equatable, Sendable {
  case cliUnavailable
  case noPullRequest
  case missingHeadCommit

  public var errorDescription: String? {
    switch self {
    case .cliUnavailable:
      "GitHub CLI was not found. Install it with `brew install gh`, then run `gh auth login`."
    case .noPullRequest:
      "This branch does not have an open pull request."
    case .missingHeadCommit:
      "Refresh the pull request before merging so Feather can pin its head commit."
    }
  }
}

public enum GitHubCLIResolver {
  public static func executablePath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> String? {
    var candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
    if let path = environment["PATH"] {
      candidates += path.split(separator: ":").map { "\($0)/gh" }
    }
    return candidates.first { fileManager.isExecutableFile(atPath: $0) }
  }
}

public actor GitHubService {
  private let runner: BoundedCommandRunner
  private let executable: String?

  public init(
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    executable: String? = GitHubCLIResolver.executablePath()
  ) {
    self.runner = runner
    self.executable = executable
  }

  public func currentPullRequest(worktreePath: String) async throws -> GitHubPullRequestSnapshot {
    guard let executable else { throw GitHubServiceError.cliUnavailable }
    let directory = URL(fileURLWithPath: worktreePath, isDirectory: true)
    let pullRequestOutput = try await runner.run(
      executable,
      arguments: [
        "pr", "view", "--json",
        "number,title,state,isDraft,url,reviewDecision,headRefName,baseRefName,headRefOid,mergeStateStatus,author",
      ],
      currentDirectory: directory,
      environment: ["GH_PROMPT_DISABLED": "1"],
      maximumOutputBytes: 512 * 1_024,
      timeout: 20
    )
    guard pullRequestOutput.status == 0 else {
      let detail = pullRequestOutput.stderrText.lowercased()
      if detail.contains("no pull request") || detail.contains("no open pull requests") {
        throw GitHubServiceError.noPullRequest
      }
      throw BoundedCommandFailure(
        executable: executable,
        arguments: ["pr", "view"],
        status: pullRequestOutput.status,
        stderr: pullRequestOutput.stderrText
      )
    }
    let pullRequest = try JSONDecoder().decode(
      GitHubPullRequest.self,
      from: pullRequestOutput.stdout
    )

    let checksOutput = try await runner.run(
      executable,
      arguments: ["pr", "checks", "--json", "name,state,bucket,link,workflow"],
      currentDirectory: directory,
      environment: ["GH_PROMPT_DISABLED": "1"],
      maximumOutputBytes: 2 * 1_024 * 1_024,
      timeout: 30
    )
    let checks: [GitHubCheck]
    if let decoded = try? JSONDecoder().decode([GitHubCheck].self, from: checksOutput.stdout) {
      checks = decoded
    } else if checksOutput.status == 0 {
      checks = []
    } else {
      throw BoundedCommandFailure(
        executable: executable,
        arguments: ["pr", "checks"],
        status: checksOutput.status,
        stderr: checksOutput.stderrText
      )
    }
    return GitHubPullRequestSnapshot(pullRequest: pullRequest, checks: checks)
  }

  public func createPullRequest(worktreePath: String) async throws {
    guard let executable else { throw GitHubServiceError.cliUnavailable }
    let output = try await runner.run(
      executable,
      arguments: ["pr", "create", "--web"],
      currentDirectory: URL(fileURLWithPath: worktreePath, isDirectory: true),
      environment: ["GH_PROMPT_DISABLED": "1"],
      maximumOutputBytes: 512 * 1_024,
      timeout: 120
    )
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: executable,
        arguments: ["pr", "create", "--web"],
        status: output.status,
        stderr: output.stderrText
      )
    }
  }

  public func mergePullRequest(
    _ pullRequest: GitHubPullRequest,
    worktreePath: String
  ) async throws {
    guard let executable else { throw GitHubServiceError.cliUnavailable }
    guard let headRefOid = pullRequest.headRefOid, !headRefOid.isEmpty else {
      throw GitHubServiceError.missingHeadCommit
    }
    let arguments = [
      "pr", "merge", String(pullRequest.number), "--squash", "--match-head-commit", headRefOid,
    ]
    let output = try await runner.run(
      executable,
      arguments: arguments,
      currentDirectory: URL(fileURLWithPath: worktreePath, isDirectory: true),
      environment: ["GH_PROMPT_DISABLED": "1"],
      maximumOutputBytes: 512 * 1_024,
      timeout: 120
    )
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: executable,
        arguments: arguments,
        status: output.status,
        stderr: output.stderrText
      )
    }
  }
}
