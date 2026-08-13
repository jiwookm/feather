import Foundation

public enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  public var id: String { rawValue }

  public var title: String {
    rawValue.capitalized
  }
}

public struct RepositoryRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var path: String
  public var displayName: String
  public var remoteURL: String?

  public init(
    id: UUID = UUID(),
    path: String,
    displayName: String,
    remoteURL: String? = nil
  ) {
    self.id = id
    self.path = path
    self.displayName = displayName
    self.remoteURL = remoteURL
  }

  public var remoteDisplayName: String? {
    guard let remoteURL = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
      !remoteURL.isEmpty
    else { return nil }

    if let url = URL(string: remoteURL), let host = url.host {
      let path = Self.withoutGitSuffix(
        url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
      return path.isEmpty ? host : "\(host)/\(path)"
    }

    if let separator = remoteURL.firstIndex(of: ":") {
      let accountAndHost = remoteURL[..<separator]
      if accountAndHost.contains("@") {
        let host =
          accountAndHost.split(separator: "@").last.map(String.init) ?? String(accountAndHost)
        let path = Self.withoutGitSuffix(String(remoteURL[remoteURL.index(after: separator)...]))
        return path.isEmpty ? host : "\(host)/\(path)"
      }
    }

    return Self.withoutGitSuffix(remoteURL)
  }

  private static func withoutGitSuffix(_ value: String) -> String {
    value.hasSuffix(".git") ? String(value.dropLast(4)) : value
  }
}

public struct GitHubRepositoryIdentity: Equatable, Sendable {
  public let owner: String
  public let repository: String

  public init?(remoteURL: String?) {
    guard let remoteURL = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
      !remoteURL.isEmpty
    else { return nil }

    let path: String
    if let url = URL(string: remoteURL), url.host?.lowercased() == "github.com" {
      path = url.path
    } else if let separator = remoteURL.firstIndex(of: ":") {
      let hostPart = remoteURL[..<separator].split(separator: "@").last?.lowercased()
      guard hostPart == "github.com" else { return nil }
      path = String(remoteURL[remoteURL.index(after: separator)...])
    } else {
      return nil
    }

    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    let owner = String(parts[0])
    let repository = String(parts[1]).replacingOccurrences(
      of: #"\.git$"#,
      with: "",
      options: .regularExpression
    )
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard !owner.isEmpty, !repository.isEmpty,
      owner.unicodeScalars.allSatisfy(allowed.contains),
      repository.unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    self.owner = owner
    self.repository = repository
  }

  public var webURL: URL {
    URL(string: "https://github.com/\(owner)/\(repository)")!
  }

  public var avatarURL: URL {
    URL(string: "https://github.com/\(owner).png?size=64")!
  }
}

/// Ownership metadata for checkouts created by Feather. Worktrees discovered
/// through Git are deliberately not inferred as managed, which keeps external
/// tools' checkouts outside Feather's deletion boundary.
public enum ManagedWorktreeState: String, Codable, Sendable {
  case active
  case available
}

public struct ManagedWorktreeRecord: Codable, Equatable, Sendable {
  public let repositoryID: UUID
  public var path: String
  public var state: ManagedWorktreeState

  public init(
    repositoryID: UUID,
    path: String,
    state: ManagedWorktreeState = .active
  ) {
    self.repositoryID = repositoryID
    self.path = path
    self.state = state
  }

  private enum CodingKeys: String, CodingKey {
    case repositoryID
    case path
    case state
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repositoryID = try container.decode(UUID.self, forKey: .repositoryID)
    path = try container.decode(String.self, forKey: .path)
    state = try container.decodeIfPresent(ManagedWorktreeState.self, forKey: .state) ?? .active
  }
}

public struct GitWorktree: Equatable, Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let head: String?
  public let branch: String?
  public let isBare: Bool
  public let isDetached: Bool
  public let isLocked: Bool
  public let isPrunable: Bool

  public init(
    path: String,
    head: String? = nil,
    branch: String? = nil,
    isBare: Bool = false,
    isDetached: Bool = false,
    isLocked: Bool = false,
    isPrunable: Bool = false
  ) {
    self.path = path
    self.head = head
    self.branch = branch
    self.isBare = isBare
    self.isDetached = isDetached
    self.isLocked = isLocked
    self.isPrunable = isPrunable
  }

  public var displayName: String {
    URL(fileURLWithPath: path).lastPathComponent
  }

  public var branchDisplayName: String? {
    branch?.replacingOccurrences(of: "refs/heads/", with: "")
  }
}

public struct TerminalRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let repositoryID: UUID
  public let worktreePath: String
  public var title: String
  public var order: Int
  public let tmuxSessionID: String

  public init(
    id: UUID = UUID(),
    repositoryID: UUID,
    worktreePath: String,
    title: String,
    order: Int,
    tmuxSessionID: String? = nil
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.worktreePath = worktreePath
    self.title = title
    self.order = order
    self.tmuxSessionID =
      tmuxSessionID
      ?? "feather-\(id.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
  }
}

public enum TerminalSplitDirection: Equatable, Sendable {
  case right
  case down
}

public struct TerminalPaneState: Equatable, Sendable {
  public let id: String
  public let command: String
  public let totalCount: Int

  public init(id: String, command: String, totalCount: Int) {
    self.id = id
    self.command = command
    self.totalCount = totalCount
  }
}

/// Renderer-independent terminal lifecycle used by the local tmux backend and
/// intended for a future SSH/tmux implementation.
public protocol TerminalBackend: Actor {
  func sessionExists(_ sessionID: String) throws -> Bool
  func ensureSession(_ sessionID: String, workingDirectory: String) throws
  func foregroundCommand(_ sessionID: String) throws -> String?
  func activePane(_ sessionID: String) throws -> TerminalPaneState?
  func splitPane(
    sessionID: String,
    workingDirectory: String,
    direction: TerminalSplitDirection
  ) throws
  func killPane(_ paneID: String, sessionID: String) throws -> Bool
  func killSession(_ sessionID: String) throws
}

public struct ApplicationSnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 4

  public var version: Int
  public var repositories: [RepositoryRecord]
  public var managedWorktrees: [ManagedWorktreeRecord]
  public var terminals: [TerminalRecord]
  public var appearance: AppearancePreference
  public var selectedRepositoryID: UUID?
  public var selectedWorktreePath: String?
  public var selectedTerminalID: UUID?
  public var sidebarVisible: Bool
  public var inspectorVisible: Bool

  public init(
    version: Int = ApplicationSnapshot.currentVersion,
    repositories: [RepositoryRecord] = [],
    managedWorktrees: [ManagedWorktreeRecord] = [],
    terminals: [TerminalRecord] = [],
    appearance: AppearancePreference = .system,
    selectedRepositoryID: UUID? = nil,
    selectedWorktreePath: String? = nil,
    selectedTerminalID: UUID? = nil,
    sidebarVisible: Bool = true,
    inspectorVisible: Bool = false
  ) {
    self.version = version
    self.repositories = repositories
    self.managedWorktrees = managedWorktrees
    self.terminals = terminals
    self.appearance = appearance
    self.selectedRepositoryID = selectedRepositoryID
    self.selectedWorktreePath = selectedWorktreePath
    self.selectedTerminalID = selectedTerminalID
    self.sidebarVisible = sidebarVisible
    self.inspectorVisible = inspectorVisible
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case repositories
    case managedWorktrees
    case terminals
    case appearance
    case selectedRepositoryID
    case selectedWorktreePath
    case selectedTerminalID
    case sidebarVisible
    case inspectorVisible
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    repositories =
      try container.decodeIfPresent([RepositoryRecord].self, forKey: .repositories) ?? []
    managedWorktrees =
      try container.decodeIfPresent([ManagedWorktreeRecord].self, forKey: .managedWorktrees) ?? []
    terminals = try container.decodeIfPresent([TerminalRecord].self, forKey: .terminals) ?? []
    appearance =
      try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
    selectedRepositoryID = try container.decodeIfPresent(UUID.self, forKey: .selectedRepositoryID)
    selectedWorktreePath = try container.decodeIfPresent(String.self, forKey: .selectedWorktreePath)
    selectedTerminalID = try container.decodeIfPresent(UUID.self, forKey: .selectedTerminalID)
    sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
    inspectorVisible = try container.decodeIfPresent(Bool.self, forKey: .inspectorVisible) ?? false
  }

}

public enum FeatherError: LocalizedError, Equatable, Sendable {
  case noWorktrees(String)
  case dirtyWorktree(String)
  case mainWorktreeRemoval
  case unmanagedWorktreeRemoval
  case activeTerminals(Int)
  case worktreeNotMerged(String)
  case tmuxUnavailable
  case malformedGitOutput

  public var errorDescription: String? {
    switch self {
    case .noWorktrees(let path):
      "Git did not report any worktrees for \(path)."
    case .dirtyWorktree(let path):
      "The worktree has uncommitted or untracked files: \(path)"
    case .mainWorktreeRemoval:
      "The registered repository's main checkout cannot be removed."
    case .unmanagedWorktreeRemoval:
      "Feather can only remove worktrees that it created and recorded."
    case .activeTerminals(let count):
      "Close the \(count) managed terminal\(count == 1 ? "" : "s") before changing this worktree."
    case .worktreeNotMerged(let path):
      "The worktree has commits that are not merged into the latest default branch: \(path)"
    case .tmuxUnavailable:
      "tmux is required. Install it with `brew install tmux`, then relaunch Feather."
    case .malformedGitOutput:
      "Git returned malformed worktree data."
    }
  }
}
