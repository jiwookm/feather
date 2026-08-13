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
  public let author: Author?
}

public struct GitHubCheck: Codable, Equatable, Identifiable, Sendable {
  public var id: String { "\(workflow ?? ""):\(name):\(link ?? "")" }
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
}

public enum GitHubServiceError: LocalizedError, Equatable, Sendable {
  case cliUnavailable
  case noPullRequest

  public var errorDescription: String? {
    switch self {
    case .cliUnavailable:
      "GitHub CLI was not found. Install it with `brew install gh`, then run `gh auth login`."
    case .noPullRequest:
      "This branch does not have an open pull request."
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
        "number,title,state,isDraft,url,reviewDecision,headRefName,baseRefName,author",
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
}
