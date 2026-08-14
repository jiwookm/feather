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
  public var executionTarget: TerminalExecutionTarget

  public init(
    id: UUID = UUID(),
    repositoryID: UUID,
    worktreePath: String,
    title: String,
    order: Int,
    tmuxSessionID: String? = nil,
    executionTarget: TerminalExecutionTarget = .local
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.worktreePath = worktreePath
    self.title = title
    self.order = order
    self.executionTarget = executionTarget
    self.tmuxSessionID =
      tmuxSessionID
      ?? "feather-\(id.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case repositoryID
    case worktreePath
    case title
    case order
    case tmuxSessionID
    case executionTarget
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    repositoryID = try container.decode(UUID.self, forKey: .repositoryID)
    worktreePath = try container.decode(String.self, forKey: .worktreePath)
    title = try container.decode(String.self, forKey: .title)
    order = try container.decode(Int.self, forKey: .order)
    tmuxSessionID = try container.decode(String.self, forKey: .tmuxSessionID)
    executionTarget =
      try container.decodeIfPresent(TerminalExecutionTarget.self, forKey: .executionTarget)
      ?? .local
  }
}

public struct SSHRemoteTarget: Codable, Equatable, Sendable {
  public var host: String
  public var port: Int
  public var rootPath: String

  public init(host: String = "", port: Int = 22, rootPath: String = "") {
    self.host = host
    self.port = port
    self.rootPath = rootPath
  }

  public var isConfigured: Bool {
    !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (1...65_535).contains(port)
      && rootPath.hasPrefix("/")
  }
}

public struct SSHRemoteProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var target: SSHRemoteTarget

  public init(
    id: UUID = UUID(),
    name: String,
    target: SSHRemoteTarget
  ) {
    self.id = id
    self.name = name
    self.target = target
  }

  public var isConfigured: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && target.isConfigured
  }
}

public struct SSHRemoteTerminal: Codable, Equatable, Sendable {
  public let target: SSHRemoteTarget
  public let workingDirectory: String
  public let tmuxConfigPath: String
  public let tmuxSocketName: String

  public init(
    target: SSHRemoteTarget,
    workingDirectory: String,
    tmuxConfigPath: String,
    tmuxSocketName: String = "feather"
  ) {
    self.target = target
    self.workingDirectory = workingDirectory
    self.tmuxConfigPath = tmuxConfigPath
    self.tmuxSocketName = tmuxSocketName
  }
}

public enum TerminalExecutionTarget: Codable, Equatable, Sendable {
  case local
  case ssh(SSHRemoteTerminal)
}

public struct RemoteWorkspaceOwnership: Codable, Equatable, Sendable {
  public let token: String
  public let markerPath: String

  public init(token: String, markerPath: String) {
    self.token = token
    self.markerPath = markerPath
  }
}

public struct RemoteHandoffStateFingerprint: Codable, Equatable, Sendable {
  public let branch: String
  public let baseCommit: String
  public let headCommit: String
  public let publishedCommit: String?
  public let statusSHA256: String
  public let indexPatchSHA256: String
  public let worktreePatchSHA256: String
  public let untrackedPathsSHA256: String
  public let untrackedEntriesSHA256: String
  public let stagedPathCount: Int
  public let unstagedPathCount: Int
  public let untrackedFileCount: Int
  public let untrackedBytes: Int64
  public let unpublishedCommitCount: Int

  public init(
    branch: String,
    baseCommit: String,
    headCommit: String,
    publishedCommit: String?,
    statusSHA256: String,
    indexPatchSHA256: String,
    worktreePatchSHA256: String,
    untrackedPathsSHA256: String,
    untrackedEntriesSHA256: String,
    stagedPathCount: Int,
    unstagedPathCount: Int,
    untrackedFileCount: Int,
    untrackedBytes: Int64,
    unpublishedCommitCount: Int
  ) {
    self.branch = branch
    self.baseCommit = baseCommit
    self.headCommit = headCommit
    self.publishedCommit = publishedCommit
    self.statusSHA256 = statusSHA256
    self.indexPatchSHA256 = indexPatchSHA256
    self.worktreePatchSHA256 = worktreePatchSHA256
    self.untrackedPathsSHA256 = untrackedPathsSHA256
    self.untrackedEntriesSHA256 = untrackedEntriesSHA256
    self.stagedPathCount = stagedPathCount
    self.unstagedPathCount = unstagedPathCount
    self.untrackedFileCount = untrackedFileCount
    self.untrackedBytes = untrackedBytes
    self.unpublishedCommitCount = unpublishedCommitCount
  }

  public var isPublishedClean: Bool {
    publishedCommit == headCommit && stagedPathCount == 0 && unstagedPathCount == 0
      && untrackedFileCount == 0
  }
}

public struct RemoteHandoffManifest: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let state: RemoteHandoffStateFingerprint
  public let bundleSHA256: String?
  public let artifactBytes: Int64

  public init(
    version: Int = RemoteHandoffManifest.currentVersion,
    state: RemoteHandoffStateFingerprint,
    bundleSHA256: String?,
    artifactBytes: Int64
  ) {
    self.version = version
    self.state = state
    self.bundleSHA256 = bundleSHA256
    self.artifactBytes = artifactBytes
  }
}

public struct RemoteHandoffPreflight: Equatable, Sendable {
  public let state: RemoteHandoffStateFingerprint
  public let transferBytes: Int64

  public init(state: RemoteHandoffStateFingerprint, transferBytes: Int64) {
    self.state = state
    self.transferBytes = transferBytes
  }
}

public struct RemoteWorkspaceReturnRecord: Codable, Equatable, Sendable {
  public let manifest: RemoteHandoffManifest
  public let cleanupSessionIDs: [String]

  public init(manifest: RemoteHandoffManifest, cleanupSessionIDs: [String]) {
    self.manifest = manifest
    self.cleanupSessionIDs = Array(Set(cleanupSessionIDs)).sorted()
  }
}

public struct RemoteWorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let repositoryID: UUID
  public let worktreePath: String
  public let profileID: UUID?
  public let profileName: String
  public let remote: SSHRemoteTerminal
  public let ownership: RemoteWorkspaceOwnership?
  public let handoff: RemoteHandoffManifest?
  public let returned: RemoteWorkspaceReturnRecord?

  public init(
    id: UUID = UUID(),
    repositoryID: UUID,
    worktreePath: String,
    profileID: UUID?,
    profileName: String,
    remote: SSHRemoteTerminal,
    ownership: RemoteWorkspaceOwnership?,
    handoff: RemoteHandoffManifest? = nil,
    returned: RemoteWorkspaceReturnRecord? = nil
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.worktreePath = worktreePath
    self.profileID = profileID
    self.profileName = profileName
    self.remote = remote
    self.ownership = ownership
    self.handoff = handoff
    self.returned = returned
  }

  public func matches(repositoryID: UUID, worktreePath: String) -> Bool {
    self.repositoryID == repositoryID && self.worktreePath == worktreePath
  }

  public var isRemoteAuthoritative: Bool { returned == nil }

  public func recordingReturn(_ record: RemoteWorkspaceReturnRecord) -> RemoteWorkspaceRecord {
    RemoteWorkspaceRecord(
      id: id,
      repositoryID: repositoryID,
      worktreePath: worktreePath,
      profileID: profileID,
      profileName: profileName,
      remote: remote,
      ownership: ownership,
      handoff: handoff,
      returned: record
    )
  }
}

public enum WorkspaceExecutionRouter {
  public static func remoteWorkspace(
    for terminal: TerminalRecord,
    in workspaces: [RemoteWorkspaceRecord]
  ) -> RemoteWorkspaceRecord? {
    remoteWorkspace(
      repositoryID: terminal.repositoryID,
      worktreePath: terminal.worktreePath,
      in: workspaces
    ).flatMap { $0.isRemoteAuthoritative ? $0 : nil }
  }

  public static func remoteWorkspace(
    repositoryID: UUID,
    worktreePath: String,
    in workspaces: [RemoteWorkspaceRecord]
  ) -> RemoteWorkspaceRecord? {
    workspaces.first { $0.matches(repositoryID: repositoryID, worktreePath: worktreePath) }
  }

  public static func target(
    for terminal: TerminalRecord,
    in workspaces: [RemoteWorkspaceRecord]
  ) -> TerminalExecutionTarget {
    remoteWorkspace(for: terminal, in: workspaces).map { .ssh($0.remote) } ?? .local
  }
}

public enum RemoteWorkspaceRuntimeState: String, Equatable, Sendable {
  case connecting
  case connected
  case offline
  case ownershipMismatch
}

public enum TerminalRuntimeState: String, Equatable, Sendable {
  case shell
  case running
  case attention
  case exited
  case offline
}

public struct TmuxSessionRuntimeSnapshot: Equatable, Sendable {
  public let sessionID: String
  public let command: String
  public let paneDead: Bool
  public let hasBell: Bool

  public init(sessionID: String, command: String, paneDead: Bool, hasBell: Bool) {
    self.sessionID = sessionID
    self.command = command
    self.paneDead = paneDead
    self.hasBell = hasBell
  }

  public var state: TerminalRuntimeState {
    if paneDead { return .exited }
    if hasBell { return .attention }
    let executable = URL(fileURLWithPath: command).lastPathComponent.lowercased()
    return Self.shellCommands.contains(executable) ? .shell : .running
  }

  private static let shellCommands: Set<String> = [
    "bash", "dash", "fish", "ksh", "login", "sh", "tcsh", "xonsh", "zsh",
  ]
}

public enum TmuxSessionRuntimeResolver {
  public static func statesBySession(
    _ snapshots: [TmuxSessionRuntimeSnapshot]
  ) -> [String: TerminalRuntimeState] {
    Dictionary(grouping: snapshots, by: \.sessionID).mapValues(resolve)
  }

  public static func state(
    for sessionID: String,
    in snapshots: [TmuxSessionRuntimeSnapshot]
  ) -> TerminalRuntimeState {
    resolve(snapshots.filter { $0.sessionID == sessionID })
  }

  private static func resolve(
    _ snapshots: [TmuxSessionRuntimeSnapshot]
  ) -> TerminalRuntimeState {
    if snapshots.contains(where: { $0.state == .attention }) { return .attention }
    if snapshots.contains(where: { $0.state == .running }) { return .running }
    if snapshots.contains(where: { $0.state == .shell }) { return .shell }
    return .exited
  }
}

public enum RemoteWorkspaceRuntimePolicy {
  public static func stateAfterAttachmentExit(
    sessionID: String,
    snapshots: [TmuxSessionRuntimeSnapshot]
  ) -> RemoteWorkspaceRuntimeState {
    TmuxSessionRuntimeResolver.state(for: sessionID, in: snapshots) == .exited
      ? .connected
      : .offline
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

/// Renderer-independent terminal lifecycle shared by local and SSH/tmux sessions.
public protocol TerminalBackend: Actor {
  func sessionExists(_ sessionID: String) async throws -> Bool
  func ensureSession(_ sessionID: String, workingDirectory: String) async throws
  func launchCommand(
    _ command: String,
    sessionID: String,
    workingDirectory: String
  ) async throws
  func foregroundCommand(_ sessionID: String) async throws -> String?
  func activePane(_ sessionID: String) async throws -> TerminalPaneState?
  func splitPane(
    sessionID: String,
    workingDirectory: String,
    direction: TerminalSplitDirection
  ) async throws
  func killPane(_ paneID: String, sessionID: String) async throws -> Bool
  func killSession(_ sessionID: String) async throws
}

public struct ApplicationSnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 8

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
  public var remoteTarget: SSHRemoteTarget
  public var remoteProfiles: [SSHRemoteProfile]
  public var selectedRemoteProfileID: UUID?
  public var remoteWorkspaces: [RemoteWorkspaceRecord]

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
    inspectorVisible: Bool = false,
    remoteTarget: SSHRemoteTarget = SSHRemoteTarget(),
    remoteProfiles: [SSHRemoteProfile] = [],
    selectedRemoteProfileID: UUID? = nil,
    remoteWorkspaces: [RemoteWorkspaceRecord] = []
  ) {
    var profiles = remoteProfiles
    if profiles.isEmpty, remoteTarget.isConfigured {
      profiles.append(SSHRemoteProfile(name: remoteTarget.host, target: remoteTarget))
    }
    for terminal in terminals {
      guard case .ssh(let remote) = terminal.executionTarget,
        !profiles.contains(where: { $0.target == remote.target })
      else { continue }
      profiles.append(SSHRemoteProfile(name: remote.target.host, target: remote.target))
    }
    let profileID =
      selectedRemoteProfileID.flatMap { selectedID in
        profiles.contains(where: { $0.id == selectedID }) ? selectedID : nil
      } ?? profiles.first?.id
    let normalized = Self.normalizeRemoteWorkspaces(
      terminals: terminals,
      remoteWorkspaces: remoteWorkspaces,
      profiles: profiles
    )

    self.version = version
    self.repositories = repositories
    self.managedWorktrees = managedWorktrees
    self.terminals = normalized.terminals
    self.appearance = appearance
    self.selectedRepositoryID = selectedRepositoryID
    self.selectedWorktreePath = selectedWorktreePath
    self.selectedTerminalID = selectedTerminalID
    self.sidebarVisible = sidebarVisible
    self.inspectorVisible = inspectorVisible
    self.remoteTarget =
      profiles.first(where: { $0.id == profileID })?.target ?? remoteTarget
    self.remoteProfiles = profiles
    self.selectedRemoteProfileID = profileID
    self.remoteWorkspaces = normalized.remoteWorkspaces
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
    case remoteTarget
    case remoteProfiles
    case selectedRemoteProfileID
    case remoteWorkspaces
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let remoteTarget =
      try container.decodeIfPresent(SSHRemoteTarget.self, forKey: .remoteTarget)
      ?? SSHRemoteTarget()
    self.init(
      version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
      repositories: try container.decodeIfPresent(
        [RepositoryRecord].self,
        forKey: .repositories
      ) ?? [],
      managedWorktrees: try container.decodeIfPresent(
        [ManagedWorktreeRecord].self,
        forKey: .managedWorktrees
      ) ?? [],
      terminals: try container.decodeIfPresent([TerminalRecord].self, forKey: .terminals) ?? [],
      appearance: try container.decodeIfPresent(
        AppearancePreference.self,
        forKey: .appearance
      ) ?? .system,
      selectedRepositoryID: try container.decodeIfPresent(
        UUID.self,
        forKey: .selectedRepositoryID
      ),
      selectedWorktreePath: try container.decodeIfPresent(
        String.self,
        forKey: .selectedWorktreePath
      ),
      selectedTerminalID: try container.decodeIfPresent(UUID.self, forKey: .selectedTerminalID),
      sidebarVisible: try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true,
      inspectorVisible: try container.decodeIfPresent(Bool.self, forKey: .inspectorVisible)
        ?? false,
      remoteTarget: remoteTarget,
      remoteProfiles: try container.decodeIfPresent(
        [SSHRemoteProfile].self,
        forKey: .remoteProfiles
      ) ?? [],
      selectedRemoteProfileID: try container.decodeIfPresent(
        UUID.self,
        forKey: .selectedRemoteProfileID
      ),
      remoteWorkspaces: try container.decodeIfPresent(
        [RemoteWorkspaceRecord].self,
        forKey: .remoteWorkspaces
      ) ?? []
    )
  }

  private static func normalizeRemoteWorkspaces(
    terminals: [TerminalRecord],
    remoteWorkspaces: [RemoteWorkspaceRecord],
    profiles: [SSHRemoteProfile]
  ) -> (terminals: [TerminalRecord], remoteWorkspaces: [RemoteWorkspaceRecord]) {
    struct WorkspaceKey: Hashable {
      let repositoryID: UUID
      let worktreePath: String
    }

    var seen: Set<WorkspaceKey> = []
    var normalizedWorkspaces: [RemoteWorkspaceRecord] = []
    for workspace in remoteWorkspaces {
      let key = WorkspaceKey(
        repositoryID: workspace.repositoryID,
        worktreePath: workspace.worktreePath
      )
      guard seen.insert(key).inserted else { continue }
      normalizedWorkspaces.append(workspace)
    }

    var normalizedTerminals = terminals
    for index in normalizedTerminals.indices {
      let terminal = normalizedTerminals[index]
      guard case .ssh(let remote) = terminal.executionTarget else { continue }
      let key = WorkspaceKey(
        repositoryID: terminal.repositoryID,
        worktreePath: terminal.worktreePath
      )
      if seen.insert(key).inserted {
        let profile = profiles.first { $0.target == remote.target }
        normalizedWorkspaces.append(
          RemoteWorkspaceRecord(
            id: terminal.id,
            repositoryID: terminal.repositoryID,
            worktreePath: terminal.worktreePath,
            profileID: profile?.id,
            profileName: profile?.name ?? remote.target.host,
            remote: remote,
            ownership: nil
          )
        )
      }
      normalizedTerminals[index].executionTarget = .local
    }

    return (normalizedTerminals, normalizedWorkspaces)
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
  case remoteWorkspaceActive(String)

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
    case .remoteWorkspaceActive(let path):
      "Return the remote workspace before changing or removing its local checkout: \(path)"
    }
  }
}
