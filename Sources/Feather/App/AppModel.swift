import AppKit
import FeatherCore
import Foundation

enum TerminalLaunch {
  case claude
  case codex
  case terminal

  var title: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    case .terminal: "Terminal"
    }
  }

  var systemImage: String {
    switch self {
    case .claude: "sparkles"
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .terminal: "terminal"
    }
  }

  var command: String? {
    switch self {
    case .claude:
      "/usr/bin/env -u NO_COLOR claude --dangerously-skip-permissions"
    case .codex:
      "/usr/bin/env -u NO_COLOR codex '--dangerously-bypass-approvals-and-sandbox'"
    case .terminal:
      nil
    }
  }
}

struct WorktreeCreation: Identifiable {
  let id = UUID()
  let repositoryID: UUID
}

struct WorkspaceShortcutTarget: Equatable, Identifiable {
  let repositoryID: UUID
  let repositoryName: String
  let worktreePath: String
  let worktreeName: String

  var id: String { "\(repositoryID.uuidString):\(worktreePath)" }
}

enum WorkspaceShortcuts {
  static let maximumCount = 9

  static func index(for key: String) -> Int? {
    guard key.count == 1, let number = Int(key), (1...maximumCount).contains(number) else {
      return nil
    }
    return number - 1
  }

  static func targets(
    repositories: [RepositoryRecord],
    worktreesFor: (RepositoryRecord) -> [GitWorktree]
  ) -> [WorkspaceShortcutTarget] {
    var targets: [WorkspaceShortcutTarget] = []
    targets.reserveCapacity(maximumCount)

    for repository in repositories {
      for worktree in worktreesFor(repository) {
        targets.append(
          WorkspaceShortcutTarget(
            repositoryID: repository.id,
            repositoryName: repository.displayName,
            worktreePath: worktree.path,
            worktreeName: worktree.branchDisplayName ?? worktree.displayName
          )
        )
        if targets.count == maximumCount { return targets }
      }
    }

    return targets
  }
}

enum AgentResponseAcknowledgementAction: Equatable {
  case keep
  case record
  case clear
}

struct PolledTerminalRuntimeDecision: Equatable {
  let state: TerminalRuntimeState
  let acknowledgement: AgentResponseAcknowledgementAction
}

enum PolledTerminalRuntimePolicy {
  static func decide(
    reportedState: TerminalRuntimeState,
    stateWithoutAttention: TerminalRuntimeState,
    agentActivity: TerminalAgentActivity?,
    isSelected: Bool,
    responseAcknowledged: Bool
  ) -> PolledTerminalRuntimeDecision {
    if reportedState == .exited {
      return PolledTerminalRuntimeDecision(state: .exited, acknowledgement: .clear)
    }
    if reportedState == .attention, !isSelected {
      return PolledTerminalRuntimeDecision(state: .attention, acknowledgement: .keep)
    }

    switch agentActivity {
    case .working:
      return PolledTerminalRuntimeDecision(state: .running, acknowledgement: .clear)
    case .waiting:
      if isSelected {
        return PolledTerminalRuntimeDecision(state: .running, acknowledgement: .record)
      }
      return PolledTerminalRuntimeDecision(
        state: responseAcknowledged ? .running : .attention,
        acknowledgement: .keep
      )
    case nil:
      return PolledTerminalRuntimeDecision(
        state: reportedState == .attention ? stateWithoutAttention : reportedState,
        acknowledgement: .clear
      )
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  enum PresentedAlert: Identifiable {
    case error(String)
    case closeTerminal(TerminalRecord, String)
    case closePane(TerminalRecord, TerminalPaneState)
    case removeWorktree(RepositoryRecord, GitWorktree, activeTerminalCount: Int)
    case returnWorktree(RepositoryRecord, GitWorktree)
    case runWorkspaceRemotely(
      RepositoryRecord,
      GitWorktree,
      SSHRemoteProfile,
      RemoteHandoffPreflight
    )
    case returnRemoteWorkspace(
      RepositoryRecord,
      GitWorktree,
      RemoteWorkspaceRecord,
      RemoteReturnPreparation
    )
    case cleanupRemoteWorkspace(RemoteWorkspaceRecord, RemoteCleanupPreflight)
    case message(String, String)

    var id: String {
      switch self {
      case .error(let message): "error-\(message)"
      case .closeTerminal(let terminal, _): "terminal-\(terminal.id)"
      case .closePane(_, let pane): "pane-\(pane.id)"
      case .removeWorktree(_, let worktree, _): "worktree-\(worktree.path)"
      case .returnWorktree(_, let worktree): "return-\(worktree.path)"
      case .runWorkspaceRemotely(let repository, let worktree, _, _):
        "remote-workspace-\(repository.id)-\(worktree.path)"
      case .returnRemoteWorkspace(_, _, let workspace, _):
        "return-remote-workspace-\(workspace.id)"
      case .cleanupRemoteWorkspace(let workspace, _):
        "cleanup-remote-workspace-\(workspace.id)"
      case .message(let title, let message): "message-\(title)-\(message)"
      }
    }
  }

  @Published private(set) var repositories: [RepositoryRecord]
  @Published private(set) var worktreesByRepository: [UUID: [GitWorktree]] = [:]
  @Published private(set) var managedWorktrees: [ManagedWorktreeRecord]
  @Published private(set) var terminals: [TerminalRecord]
  @Published private(set) var terminalRuntimeStates: [UUID: TerminalRuntimeState] = [:]
  @Published private(set) var terminalRuntimeAgentKinds: [UUID: TerminalAgentKind] = [:]
  @Published private(set) var observedTerminalRuntimeIDs: Set<UUID> = []
  @Published private(set) var pendingWorktree: WorktreeCreation?
  @Published private(set) var selectedPendingWorktreeID: UUID?
  @Published var selectedRepositoryID: UUID?
  @Published var selectedWorktreePath: String?
  @Published var selectedTerminalID: UUID?
  @Published var sidebarVisible: Bool
  @Published var inspectorVisible: Bool
  @Published var isBusy = false
  @Published private(set) var hasOpenWorkspaceDocuments = false
  @Published var presentedAlert: PresentedAlert?
  @Published var projectRemovalCandidate: RepositoryRecord?
  @Published var appearance: AppearancePreference {
    didSet {
      guard oldValue != appearance else { return }
      terminalRegistry.updateAppearance(appearance)
      persist()
    }
  }
  @Published private(set) var remoteProfiles: [SSHRemoteProfile]
  @Published private(set) var selectedRemoteProfileID: UUID?
  @Published private(set) var remoteWorkspaces: [RemoteWorkspaceRecord]
  @Published private(set) var remoteWorkspaceRuntimeStates: [UUID: RemoteWorkspaceRuntimeState] =
    [:]

  let stateStore: JSONStateStore
  let gitService = GitService()
  let remoteHandoffService: RemoteHandoffService
  let remoteReturnService: RemoteReturnService
  let tmuxBackend: TmuxBackend?
  let tmuxSpec: TmuxLaunchSpec?
  let terminalRegistry: TerminalRegistry
  let worktreesRoot: URL
  let runtimeIdentity: FeatherRuntimeIdentity
  private let processShutdown: FeatherProcessShutdown
  private var hasStarted = false
  private var terminalMonitorTask: Task<Void, Never>?
  private var acknowledgedAgentResponses: Set<UUID> = []

  init(runtimeIdentity: FeatherRuntimeIdentity = .current) {
    self.runtimeIdentity = runtimeIdentity
    let fallbackSupport = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
      .appendingPathComponent(
        runtimeIdentity.applicationSupportDirectoryName,
        isDirectory: true
      )
    let applicationSupportURL =
      (try? JSONStateStore.applicationSupportURL(
        directoryName: runtimeIdentity.applicationSupportDirectoryName,
        legacyDirectoryName: runtimeIdentity.legacyApplicationSupportDirectoryName
      )) ?? fallbackSupport
    stateStore = JSONStateStore(fileURL: applicationSupportURL.appendingPathComponent("state.json"))
    remoteHandoffService = RemoteHandoffService(
      controlDirectoryName: runtimeIdentity.remoteControlDirectoryName,
      tmuxSocketName: runtimeIdentity.remoteTmuxSocketName
    )
    remoteReturnService = RemoteReturnService()
    let snapshot = (try? stateStore.load()) ?? ApplicationSnapshot()
    repositories = snapshot.repositories
    managedWorktrees = snapshot.managedWorktrees
    terminals = snapshot.terminals
    appearance = snapshot.appearance
    selectedRepositoryID = snapshot.selectedRepositoryID
    selectedWorktreePath = snapshot.selectedWorktreePath
    selectedTerminalID = snapshot.selectedTerminalID
    sidebarVisible = snapshot.sidebarVisible
    inspectorVisible = snapshot.inspectorVisible
    remoteProfiles = snapshot.remoteProfiles
    selectedRemoteProfileID = snapshot.selectedRemoteProfileID
    remoteWorkspaces = snapshot.remoteWorkspaces
    remoteWorkspaceRuntimeStates = Dictionary(
      snapshot.remoteWorkspaces.compactMap {
        $0.isRemoteAuthoritative ? ($0.id, RemoteWorkspaceRuntimeState.connecting) : nil
      },
      uniquingKeysWith: { first, _ in first }
    )
    worktreesRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Developer/Worktrees", isDirectory: true)

    let preparedSpec = try? TmuxEnvironment.prepare(
      applicationSupportURL: applicationSupportURL,
      socketName: runtimeIdentity.localTmuxSocketName
    )
    tmuxSpec = preparedSpec
    let preparedBackend = preparedSpec.map { TmuxBackend(spec: $0) }
    tmuxBackend = preparedBackend
    let localServerTermination: FeatherProcessShutdown.LocalServerTermination?
    if let preparedBackend {
      localServerTermination = { try await preparedBackend.killServer() }
    } else {
      localServerTermination = nil
    }
    processShutdown = FeatherProcessShutdown(
      terminateLocalServer: localServerTermination,
      terminateRemoteServer: { remote in
        try await SSHTmuxBackend(remote: remote).killServer()
      }
    )
    terminalRegistry = TerminalRegistry(
      applicationSupportURL: applicationSupportURL,
      launchSpec: preparedSpec
    )
    terminalRegistry.runtimeEventHandler = { [weak self] terminalID, event in
      self?.handleTerminalRuntimeEvent(terminalID: terminalID, event: event)
    }
  }

  var selectedRepository: RepositoryRecord? {
    repositories.first { $0.id == selectedRepositoryID }
  }

  var selectedWorktree: GitWorktree? {
    guard let selectedRepositoryID, let selectedWorktreePath else { return nil }
    return worktreesByRepository[selectedRepositoryID]?.first { $0.path == selectedWorktreePath }
  }

  var selectedTerminal: TerminalRecord? {
    terminals.first { $0.id == selectedTerminalID }
  }

  var selectedPendingWorktree: WorktreeCreation? {
    guard pendingWorktree?.id == selectedPendingWorktreeID else { return nil }
    return pendingWorktree
  }

  var selectedManagedWorktreeState: ManagedWorktreeState? {
    guard let selectedRepositoryID, let selectedWorktreePath else { return nil }
    return managedWorktreeState(repositoryID: selectedRepositoryID, path: selectedWorktreePath)
  }

  var selectedRemoteProfile: SSHRemoteProfile? {
    remoteProfiles.first { $0.id == selectedRemoteProfileID }
  }

  var remoteTarget: SSHRemoteTarget {
    selectedRemoteProfile?.target ?? SSHRemoteTarget()
  }

  var selectedRemoteWorkspace: RemoteWorkspaceRecord? {
    guard let selectedRepositoryID, let selectedWorktreePath else { return nil }
    return remoteWorkspace(repositoryID: selectedRepositoryID, worktreePath: selectedWorktreePath)
  }

  var selectedAuthoritativeRemoteWorkspace: RemoteWorkspaceRecord? {
    selectedRemoteWorkspace.flatMap { $0.isRemoteAuthoritative ? $0 : nil }
  }

  var canCreateTerminal: Bool {
    guard selectedWorktree != nil, selectedManagedWorktreeState != .available else { return false }
    guard let workspace = selectedAuthoritativeRemoteWorkspace else { return true }
    return remoteWorkspaceRuntimeStates[workspace.id] == .connected
  }

  var canRunSelectedWorkspaceRemotely: Bool {
    guard !isBusy, selectedRemoteProfile?.isConfigured == true,
      let selectedRepositoryID, let selectedWorktreePath,
      selectedRemoteWorkspace == nil,
      selectedManagedWorktreeState != .available,
      !hasOpenWorkspaceDocuments
    else { return false }
    return terminals(repositoryID: selectedRepositoryID, worktreePath: selectedWorktreePath).isEmpty
  }

  var canReconnectSelectedRemoteWorkspace: Bool {
    !isBusy && selectedAuthoritativeRemoteWorkspace != nil
  }

  var canReturnSelectedRemoteWorkspace: Bool {
    !isBusy && !hasOpenWorkspaceDocuments
      && selectedAuthoritativeRemoteWorkspace?.handoff != nil
      && selectedAuthoritativeRemoteWorkspace?.ownership != nil
  }

  var canCleanupSelectedRemoteWorkspace: Bool {
    !isBusy && selectedRemoteWorkspace?.returned != nil
  }

  var selectedWorktreeTerminals: [TerminalRecord] {
    guard let selectedRepositoryID, let selectedWorktreePath else { return [] }
    return terminals(repositoryID: selectedRepositoryID, worktreePath: selectedWorktreePath)
  }

  var setupError: String? {
    if selectedAuthoritativeRemoteWorkspace == nil, tmuxSpec == nil {
      return FeatherError.tmuxUnavailable.localizedDescription
    }
    return terminalRegistry.initializationError
  }

  func projectWorktrees(for repository: RepositoryRecord) -> [GitWorktree] {
    let managedPaths = Set(
      managedWorktrees
        .filter { $0.repositoryID == repository.id }
        .map(\.path)
    )
    return (worktreesByRepository[repository.id] ?? [])
      .filter { managedPaths.contains($0.path) }
      .sorted { left, right in
        let leftState = managedWorktreeState(repositoryID: repository.id, path: left.path)
        let rightState = managedWorktreeState(repositoryID: repository.id, path: right.path)
        if leftState != rightState { return leftState == .active }
        return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
      }
  }

  var workspaceShortcutTargets: [WorkspaceShortcutTarget] {
    WorkspaceShortcuts.targets(
      repositories: repositories,
      worktreesFor: { projectWorktrees(for: $0) }
    )
  }

  func externalWorktrees(for repository: RepositoryRecord) -> [GitWorktree] {
    let managedPaths = Set(projectWorktrees(for: repository).map(\.path))
    return (worktreesByRepository[repository.id] ?? []).filter {
      $0.path != repository.path && !managedPaths.contains($0.path)
    }
  }

  func isManagedWorktree(repositoryID: UUID, path: String) -> Bool {
    managedWorktrees.contains { $0.repositoryID == repositoryID && $0.path == path }
  }

  func pendingCreation(for repository: RepositoryRecord) -> WorktreeCreation? {
    guard pendingWorktree?.repositoryID == repository.id else { return nil }
    return pendingWorktree
  }

  func managedWorktreeState(repositoryID: UUID, path: String) -> ManagedWorktreeState? {
    managedWorktrees.first { $0.repositoryID == repositoryID && $0.path == path }?.state
  }

  func managedWorktreeCount(for repository: RepositoryRecord) -> Int {
    managedWorktrees.count { $0.repositoryID == repository.id }
  }

  func terminalCount(for repository: RepositoryRecord) -> Int {
    terminals.count { $0.repositoryID == repository.id }
  }

  func terminals(repositoryID: UUID, worktreePath: String) -> [TerminalRecord] {
    terminals
      .filter { $0.repositoryID == repositoryID && $0.worktreePath == worktreePath }
      .sorted { $0.order < $1.order }
  }

  func remoteWorkspace(
    repositoryID: UUID,
    worktreePath: String
  ) -> RemoteWorkspaceRecord? {
    WorkspaceExecutionRouter.remoteWorkspace(
      repositoryID: repositoryID,
      worktreePath: worktreePath,
      in: remoteWorkspaces
    )
  }

  func remoteWorkspace(for terminal: TerminalRecord) -> RemoteWorkspaceRecord? {
    WorkspaceExecutionRouter.remoteWorkspace(for: terminal, in: remoteWorkspaces)
  }

  func executionTarget(for terminal: TerminalRecord) -> TerminalExecutionTarget {
    WorkspaceExecutionRouter.target(for: terminal, in: remoteWorkspaces)
  }

  func remoteWorkspaceState(
    repositoryID: UUID,
    worktreePath: String
  ) -> RemoteWorkspaceRuntimeState? {
    guard let workspace = remoteWorkspace(repositoryID: repositoryID, worktreePath: worktreePath),
      workspace.isRemoteAuthoritative
    else { return nil }
    return remoteWorkspaceRuntimeStates[workspace.id] ?? .connecting
  }

  func moveRepositoryToTop(_ repository: RepositoryRecord) {
    guard let index = repositories.firstIndex(where: { $0.id == repository.id }), index > 0 else {
      return
    }
    let moved = repositories.remove(at: index)
    repositories.insert(moved, at: 0)
    persist()
  }

  func updateWorkspaceDocumentState(hasOpenDocuments: Bool) {
    hasOpenWorkspaceDocuments = hasOpenDocuments
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    Task {
      do {
        try await gitService.prepareWorktreesRoot(worktreesRoot)
      } catch {
        show(error)
      }
      await refreshAll()
      await refreshRemoteWorkspaceStates()
      await ensureTerminalMonitorSession()
      updateTerminalMonitor()
    }
  }

  func terminateProcessesForQuit() async throws {
    terminalMonitorTask?.cancel()
    terminalMonitorTask = nil
    do {
      try await processShutdown.terminateAll(
        terminals: terminals,
        remoteWorkspaces: remoteWorkspaces
      )
    } catch {
      updateTerminalMonitor()
      throw error
    }
    for terminal in terminals {
      terminalRegistry.release(terminal.id)
      terminalRuntimeStates[terminal.id] = .exited
    }
  }

  func chooseAndRegisterRepository() {
    let panel = NSOpenPanel()
    panel.title = "Add Git Project"
    panel.message = "Choose a Git repository or one of its worktrees."
    panel.prompt = "Add Project"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await registerRepository(at: url) }
  }

  func registerRepository(at url: URL) async {
    isBusy = true
    defer { isBusy = false }
    do {
      let (inspected, worktrees) = try await gitService.inspectRepository(at: url)
      let repository: RepositoryRecord
      if let index = repositories.firstIndex(where: { $0.path == inspected.path }) {
        repositories[index].displayName = inspected.displayName
        repositories[index].remoteURL = inspected.remoteURL
        repository = repositories[index]
      } else {
        repository = inspected
        repositories.append(repository)
      }
      worktreesByRepository[repository.id] = worktrees
      let selectedPath = url.standardizedFileURL.path
      let initialWorktree =
        worktrees
        .filter { selectedPath == $0.path || selectedPath.hasPrefix($0.path + "/") }
        .max { $0.path.count < $1.path.count }
        ?? worktrees[0]
      selectWorktree(repositoryID: repository.id, path: initialWorktree.path)
    } catch {
      show(error)
    }
  }

  func refreshAll() async {
    guard !repositories.isEmpty else { return }
    isBusy = true
    defer { isBusy = false }
    for repository in repositories {
      do {
        let (inspected, worktrees) = try await gitService.inspectRepository(
          at: URL(fileURLWithPath: repository.path)
        )
        if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
          repositories[index].path = inspected.path
          repositories[index].displayName = inspected.displayName
          repositories[index].remoteURL = inspected.remoteURL
        }
        worktreesByRepository[repository.id] = worktrees
        let livePaths = Set(worktrees.map(\.path))
        managedWorktrees.removeAll {
          $0.repositoryID == repository.id && !livePaths.contains($0.path)
        }
      } catch {
        show(error)
      }
    }
    reconcileSelection()
  }

  func refresh() {
    Task { await refreshAll() }
  }

  func selectWorktree(repositoryID: UUID, path: String) {
    selectedPendingWorktreeID = nil
    selectedRepositoryID = repositoryID
    selectedWorktreePath = path
    let matching =
      terminals
      .filter { $0.repositoryID == repositoryID && $0.worktreePath == path }
      .sorted { $0.order < $1.order }
    if let first = matching.first {
      selectedTerminalID =
        matching.contains(where: { $0.id == selectedTerminalID })
        ? selectedTerminalID
        : first.id
    } else {
      selectedTerminalID = nil
    }
    acknowledgeAttentionIfNeeded(selectedTerminalID)
    refreshSelectedRemoteTerminalStatesIfNeeded()
    persist()
  }

  func selectWorkspaceShortcut(at index: Int) {
    guard workspaceShortcutTargets.indices.contains(index) else { return }
    let target = workspaceShortcutTargets[index]
    selectWorktree(repositoryID: target.repositoryID, path: target.worktreePath)
  }

  func selectPendingWorktree(_ id: UUID) {
    guard let pendingWorktree, pendingWorktree.id == id else { return }
    selectedPendingWorktreeID = id
    selectedRepositoryID = pendingWorktree.repositoryID
    selectedWorktreePath = nil
    selectedTerminalID = nil
  }

  func selectTerminal(_ id: UUID) {
    selectedTerminalID = id
    acknowledgeAttentionIfNeeded(id)
    refreshSelectedRemoteTerminalStatesIfNeeded()
    persist()
  }

  func runtimeState(for terminal: TerminalRecord) -> TerminalRuntimeState {
    if let workspace = remoteWorkspace(for: terminal),
      let state = remoteWorkspaceRuntimeStates[workspace.id],
      state == .offline || state == .ownershipMismatch
    {
      return .offline
    }
    return terminalRuntimeStates[terminal.id]
      ?? (AgentKind(terminal: terminal) == nil ? .shell : .running)
  }

  func currentAgentKind(for terminal: TerminalRecord) -> TerminalAgentKind? {
    if observedTerminalRuntimeIDs.contains(terminal.id) {
      return terminalRuntimeAgentKinds[terminal.id]
    }
    guard let savedKind = AgentKind(terminal: terminal) else { return nil }
    return switch savedKind {
    case .claude: .claude
    case .codex: .codex
    }
  }

  func terminalSurfaceDidAttach(_ terminal: TerminalRecord) {
    if let workspace = remoteWorkspace(for: terminal) {
      guard remoteWorkspaceRuntimeStates[workspace.id] == .connected else {
        terminalRuntimeStates[terminal.id] = .offline
        return
      }
      if terminalRuntimeStates[terminal.id] == nil {
        terminalRuntimeStates[terminal.id] =
          AgentKind(terminal: terminal) == nil ? .shell : .running
      }
      return
    }
    if terminalRuntimeStates[terminal.id] == nil || terminalRuntimeStates[terminal.id] == .exited {
      terminalRuntimeStates[terminal.id] =
        AgentKind(terminal: terminal) == nil ? .shell : .running
    }
    updateTerminalMonitor()
  }

  func selectAdjacentTerminal(reverse: Bool = false) {
    let available = selectedWorktreeTerminals
    guard available.count > 1 else { return }

    let currentIndex = available.firstIndex { $0.id == selectedTerminalID }
    let nextIndex: Int
    if let currentIndex {
      nextIndex = (currentIndex + (reverse ? -1 : 1) + available.count) % available.count
    } else {
      nextIndex = reverse ? available.count - 1 : 0
    }
    selectTerminal(available[nextIndex].id)
  }

  func newTerminal(launch: TerminalLaunch = .terminal) {
    guard !isBusy else { return }
    guard canCreateTerminal else { return }
    guard let repositoryID = selectedRepositoryID, let worktreePath = selectedWorktreePath else {
      return
    }
    let command = launch.command
    let terminal = makeTerminal(
      repositoryID: repositoryID,
      worktreePath: worktreePath,
      title: command == nil ? nil : launch.title
    )
    guard let backend = terminalBackend(for: terminal) else {
      presentedAlert = .error(FeatherError.tmuxUnavailable.localizedDescription)
      return
    }
    let workingDirectory = terminalWorkingDirectory(terminal)

    isBusy = true
    Task {
      do {
        if let command {
          try await backend.launchCommand(
            command,
            sessionID: terminal.tmuxSessionID,
            workingDirectory: workingDirectory
          )
        } else {
          try await backend.ensureSession(
            terminal.tmuxSessionID,
            workingDirectory: workingDirectory
          )
        }
        markRemoteWorkspaceConnected(for: terminal)
        addTerminal(terminal)
      } catch {
        markRemoteWorkspaceOfflineIfNeeded(error, for: terminal)
        show(error)
      }
      isBusy = false
    }
  }

  func splitTerminal(_ direction: TerminalSplitDirection) {
    guard let terminal = selectedTerminal, let backend = terminalBackend(for: terminal) else {
      return
    }
    Task {
      do {
        try await backend.splitPane(
          sessionID: terminal.tmuxSessionID,
          workingDirectory: terminalWorkingDirectory(terminal),
          direction: direction
        )
      } catch {
        markRemoteWorkspaceOfflineIfNeeded(error, for: terminal)
        show(error)
      }
    }
  }

  private func makeTerminal(
    repositoryID: UUID,
    worktreePath: String,
    title: String? = nil
  ) -> TerminalRecord {
    let existing = terminals.filter {
      $0.repositoryID == repositoryID && $0.worktreePath == worktreePath
    }
    let nextOrder = (existing.map(\.order).max() ?? -1) + 1
    return TerminalRecord(
      repositoryID: repositoryID,
      worktreePath: worktreePath,
      title: title ?? "Terminal \(nextOrder + 1)",
      order: nextOrder
    )
  }

  private func addTerminal(_ terminal: TerminalRecord) {
    terminals.append(terminal)
    observedTerminalRuntimeIDs.remove(terminal.id)
    terminalRuntimeAgentKinds.removeValue(forKey: terminal.id)
    acknowledgedAgentResponses.remove(terminal.id)
    terminalRuntimeStates[terminal.id] =
      AgentKind(terminal: terminal) == nil ? .shell : .running
    selectedTerminalID = terminal.id
    persist()
    updateTerminalMonitor()
  }

  func requestCloseTerminal(_ id: UUID? = nil, requiresConfirmation: Bool = true) {
    guard !isBusy else { return }
    guard let terminal = terminals.first(where: { $0.id == (id ?? selectedTerminalID) }) else {
      return
    }
    guard requiresConfirmation else {
      Task { await closeTerminal(terminal) }
      return
    }
    Task {
      do {
        let command =
          try await terminalBackend(for: terminal)?.foregroundCommand(terminal.tmuxSessionID)
          ?? "terminal process"
        presentedAlert = .closeTerminal(terminal, command)
      } catch {
        show(error)
      }
    }
  }

  func requestCloseContext() {
    guard !isBusy else { return }
    guard let terminal = selectedTerminal, let backend = terminalBackend(for: terminal) else {
      requestCloseTerminal()
      return
    }
    Task {
      do {
        guard let pane = try await backend.activePane(terminal.tmuxSessionID) else {
          presentedAlert = .closeTerminal(terminal, "terminal process")
          return
        }
        presentedAlert =
          pane.totalCount > 1
          ? .closePane(terminal, pane)
          : .closeTerminal(terminal, pane.command)
      } catch {
        show(error)
      }
    }
  }

  func confirmCloseTerminal(_ terminal: TerminalRecord) {
    Task { await closeTerminal(terminal) }
  }

  func confirmClosePane(_ pane: TerminalPaneState, in terminal: TerminalRecord) {
    guard let backend = terminalBackend(for: terminal) else { return }
    Task {
      do {
        guard try await backend.killPane(pane.id, sessionID: terminal.tmuxSessionID) else {
          presentedAlert = .error("That pane changed. Press ⌘W again to close the active pane.")
          return
        }
      } catch {
        show(error)
      }
    }
  }

  func requestRemoveWorktree(repository: RepositoryRecord, worktree: GitWorktree) {
    guard remoteWorkspace(repositoryID: repository.id, worktreePath: worktree.path) == nil else {
      presentedAlert = .error(
        FeatherError.remoteWorkspaceActive(worktree.path).localizedDescription)
      return
    }
    guard isManagedWorktree(repositoryID: repository.id, path: worktree.path) else {
      presentedAlert = .error(FeatherError.unmanagedWorktreeRemoval.localizedDescription)
      return
    }
    guard repository.path != worktree.path else {
      presentedAlert = .error(FeatherError.mainWorktreeRemoval.localizedDescription)
      return
    }
    Task {
      do {
        guard try await gitService.isClean(worktreePath: worktree.path) else {
          throw FeatherError.dirtyWorktree(worktree.path)
        }
        let activeTerminalCount = terminals.count {
          $0.repositoryID == repository.id && $0.worktreePath == worktree.path
        }
        presentedAlert = .removeWorktree(
          repository,
          worktree,
          activeTerminalCount: activeTerminalCount
        )
      } catch {
        show(error)
      }
    }
  }

  func confirmRemoveWorktree(
    repository: RepositoryRecord,
    worktree: GitWorktree,
    stopActiveTerminals: Bool
  ) {
    Task {
      isBusy = true
      defer { isBusy = false }
      let visibleWorktrees = worktreesByRepository[repository.id]
      do {
        let activeTerminalCount = terminals.count {
          $0.repositoryID == repository.id && $0.worktreePath == worktree.path
        }
        if activeTerminalCount > 0 {
          guard stopActiveTerminals else {
            presentedAlert = .removeWorktree(
              repository,
              worktree,
              activeTerminalCount: activeTerminalCount
            )
            return
          }
        }

        worktreesByRepository[repository.id]?.removeAll { $0.path == worktree.path }
        reconcileSelection()

        if activeTerminalCount > 0 {
          try await terminateTerminals(
            repositoryID: repository.id,
            worktreePath: worktree.path
          )
        }
        try await gitService.removeWorktree(
          repositoryPath: repository.path,
          worktreePath: worktree.path
        )
        managedWorktrees.removeAll {
          $0.repositoryID == repository.id && $0.path == worktree.path
        }
        reconcileSelection()
      } catch {
        worktreesByRepository[repository.id] =
          (try? await gitService.listWorktrees(repositoryPath: repository.path)) ?? visibleWorktrees
        reconcileSelection()
        show(error)
      }
    }
  }

  func requestReturnWorktree(repository: RepositoryRecord, worktree: GitWorktree) {
    guard remoteWorkspace(repositoryID: repository.id, worktreePath: worktree.path) == nil else {
      presentedAlert = .error(
        FeatherError.remoteWorkspaceActive(worktree.path).localizedDescription)
      return
    }
    guard managedWorktreeState(repositoryID: repository.id, path: worktree.path) == .active else {
      return
    }
    let terminalCount = terminals.count {
      $0.repositoryID == repository.id && $0.worktreePath == worktree.path
    }
    guard terminalCount == 0 else {
      presentedAlert = .error(FeatherError.activeTerminals(terminalCount).localizedDescription)
      return
    }
    presentedAlert = .returnWorktree(repository, worktree)
  }

  func confirmReturnWorktree(repository: RepositoryRecord, worktree: GitWorktree) {
    transitionWorktree(repository: repository, worktree: worktree, from: .active, to: .available)
  }

  func reuseWorktree(repository: RepositoryRecord, worktree: GitWorktree) {
    transitionWorktree(repository: repository, worktree: worktree, from: .available, to: .active)
  }

  private func transitionWorktree(
    repository: RepositoryRecord,
    worktree: GitWorktree,
    from currentState: ManagedWorktreeState,
    to nextState: ManagedWorktreeState
  ) {
    guard !isBusy,
      managedWorktreeState(repositoryID: repository.id, path: worktree.path) == currentState
    else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let prepared = try await gitService.prepareWorktreeForReuse(
          repositoryPath: repository.path,
          worktreePath: worktree.path
        )
        updateWorktree(prepared, repositoryID: repository.id)
        setManagedWorktreeState(nextState, repositoryID: repository.id, path: prepared.path)
        if nextState == .active {
          selectWorktree(repositoryID: repository.id, path: prepared.path)
        } else {
          persist()
        }
      } catch {
        show(error)
      }
    }
  }

  func requestRemoveProject(_ repository: RepositoryRecord) {
    projectRemovalCandidate = repository
  }

  func confirmRemoveProject(
    _ repository: RepositoryRecord,
    deleteManagedWorktrees: Bool
  ) {
    projectRemovalCandidate = nil
    Task { await removeProject(repository, deleteManagedWorktrees: deleteManagedWorktrees) }
  }

  func createWorktree(for repository: RepositoryRecord? = nil) {
    guard !isBusy, let repository = repository ?? selectedRepository else { return }
    let pending = WorktreeCreation(repositoryID: repository.id)
    pendingWorktree = pending
    selectPendingWorktree(pending.id)
    isBusy = true
    Task { await createWorktreeNow(for: repository, pending: pending) }
  }

  private func createWorktreeNow(
    for repository: RepositoryRecord,
    pending: WorktreeCreation
  ) async {
    defer { isBusy = false }
    do {
      let reusablePaths =
        managedWorktrees
        .filter { $0.repositoryID == repository.id && $0.state == .available }
        .map(\.path)
      let created = try await gitService.acquireWorktree(
        repositoryPath: repository.path,
        worktreesRoot: worktreesRoot,
        reusablePaths: reusablePaths
      )
      if isManagedWorktree(repositoryID: repository.id, path: created.path) {
        setManagedWorktreeState(.active, repositoryID: repository.id, path: created.path)
      } else {
        managedWorktrees.append(
          ManagedWorktreeRecord(
            repositoryID: repository.id,
            path: created.path
          )
        )
      }
      updateWorktree(created, repositoryID: repository.id)
      let shouldSelect = selectedPendingWorktreeID == pending.id
      pendingWorktree = nil
      if shouldSelect {
        selectedPendingWorktreeID = nil
        selectedRepositoryID = repository.id
        selectedWorktreePath = created.path
        selectedTerminalID = nil
      }
      persist()
    } catch {
      let shouldRestoreSelection = selectedPendingWorktreeID == pending.id
      pendingWorktree = nil
      selectedPendingWorktreeID = nil
      if shouldRestoreSelection {
        selectWorktree(repositoryID: repository.id, path: repository.path)
      }
      show(error)
    }
  }

  func revealSelectedWorktree() {
    guard let selectedWorktreePath else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedWorktreePath)])
  }

  func selectRemoteProfile(_ id: UUID?) {
    guard id == nil || remoteProfiles.contains(where: { $0.id == id }) else { return }
    selectedRemoteProfileID = id
    persist()
  }

  func saveRemoteProfile(id: UUID?, name: String, target: SSHRemoteTarget) {
    do {
      let profile = try SSHRemoteProfileValidator.validate(
        id: id ?? UUID(),
        name: name,
        target: target
      )
      guard
        !remoteProfiles.contains(where: {
          $0.id != profile.id
            && $0.name.caseInsensitiveCompare(profile.name) == .orderedSame
        })
      else {
        presentedAlert = .error("An SSH profile named \"\(profile.name)\" already exists.")
        return
      }
      if let index = remoteProfiles.firstIndex(where: { $0.id == profile.id }) {
        remoteProfiles[index] = profile
      } else {
        remoteProfiles.append(profile)
      }
      selectedRemoteProfileID = profile.id
      persist()
      presentedAlert = .message("SSH Profile Saved", profile.name)
    } catch {
      show(error)
    }
  }

  func deleteRemoteProfile(_ id: UUID) {
    guard !remoteWorkspaces.contains(where: { $0.profileID == id }) else {
      presentedAlert = .error(
        "This SSH profile is used by a remote workspace and cannot be deleted yet."
      )
      return
    }
    remoteProfiles.removeAll { $0.id == id }
    if selectedRemoteProfileID == id { selectedRemoteProfileID = remoteProfiles.first?.id }
    persist()
  }

  func remoteProfileIsInUse(_ id: UUID) -> Bool {
    remoteWorkspaces.contains { $0.profileID == id }
  }

  func testRemoteTarget(_ target: SSHRemoteTarget) {
    guard !isBusy else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        try await remoteHandoffService.checkTarget(target)
        presentedAlert = .message(
          "Remote Target Ready",
          "SSH connected successfully, and Git, tmux, tar, base64, and SHA-256 tooling are installed."
        )
      } catch {
        show(error)
      }
    }
  }

  func requestRunSelectedWorkspaceRemotely() {
    guard !isBusy, let repository = selectedRepository, let worktree = selectedWorktree,
      let profile = selectedRemoteProfile
    else {
      if selectedRemoteProfile == nil {
        presentedAlert = .error("Add and select an SSH profile in Settings first.")
      }
      return
    }
    guard remoteWorkspace(repositoryID: repository.id, worktreePath: worktree.path) == nil else {
      presentedAlert = .message("Already Remote", "This worktree already runs remotely.")
      return
    }
    guard managedWorktreeState(repositoryID: repository.id, path: worktree.path) != .available
    else {
      presentedAlert = .error("Reuse this worktree before choosing a remote execution location.")
      return
    }
    guard !hasOpenWorkspaceDocuments else {
      presentedAlert = .error(
        "Close every open file tab before switching this worktree to remote execution."
      )
      return
    }
    let activeTerminals = terminals(repositoryID: repository.id, worktreePath: worktree.path).count
    guard activeTerminals == 0 else {
      presentedAlert = .error(
        "Close the \(activeTerminals) terminal\(activeTerminals == 1 ? "" : "s") in this worktree "
          + "before switching its authoritative execution location."
      )
      return
    }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let preflight = try await remoteHandoffService.preflightWorkspace(
          worktreePath: worktree.path
        )
        guard remoteWorkspace(repositoryID: repository.id, worktreePath: worktree.path) == nil,
          terminals(repositoryID: repository.id, worktreePath: worktree.path).isEmpty,
          !hasOpenWorkspaceDocuments
        else { return }
        presentedAlert = .runWorkspaceRemotely(repository, worktree, profile, preflight)
      } catch {
        show(error)
      }
    }
  }

  func confirmRunWorkspaceRemotely(
    repository: RepositoryRecord,
    worktree: GitWorktree,
    profile: SSHRemoteProfile,
    preflight: RemoteHandoffPreflight
  ) {
    guard !isBusy,
      remoteWorkspace(repositoryID: repository.id, worktreePath: worktree.path) == nil,
      managedWorktreeState(repositoryID: repository.id, path: worktree.path) != .available,
      !hasOpenWorkspaceDocuments,
      terminals(repositoryID: repository.id, worktreePath: worktree.path).isEmpty
    else { return }
    let workspaceID = UUID()
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let preparation = try await remoteHandoffService.prepareWorkspace(
          repository: repository,
          worktreePath: worktree.path,
          workspaceID: workspaceID,
          target: profile.target,
          expectedPreflight: preflight
        )
        let workspace = RemoteWorkspaceRecord(
          id: workspaceID,
          repositoryID: repository.id,
          worktreePath: worktree.path,
          profileID: profile.id,
          profileName: profile.name,
          remote: preparation.remote,
          ownership: preparation.ownership,
          handoff: preparation.manifest
        )
        remoteWorkspaces.append(workspace)
        remoteWorkspaceRuntimeStates[workspace.id] = .connected
        persist()
        updateTerminalMonitor()
        presentedAlert = .message(
          "Remote Workspace Ready",
          "New Claude, Codex, and shell terminals for this worktree will run on \(profile.name)."
        )
      } catch {
        show(error)
      }
    }
  }

  func requestReturnSelectedRemoteWorkspace() {
    guard !isBusy, let repository = selectedRepository, let worktree = selectedWorktree,
      let workspace = selectedAuthoritativeRemoteWorkspace
    else { return }
    guard workspace.handoff != nil, workspace.ownership != nil else {
      presentedAlert = .error(
        "This saved workspace predates verified transfer metadata. Feather kept both copies and "
          + "cannot overwrite or delete either one automatically."
      )
      return
    }
    guard !hasOpenWorkspaceDocuments else {
      presentedAlert = .error(
        "Close every open file tab before returning this workspace to the local checkout."
      )
      return
    }
    let sessionIDs = terminals(repositoryID: repository.id, worktreePath: worktree.path)
      .map(\.tmuxSessionID)
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let preparation = try await remoteReturnService.prepareReturn(
          workspace: workspace,
          localWorktreePath: worktree.path,
          recordedSessionIDs: sessionIDs
        )
        guard
          remoteWorkspace(repositoryID: repository.id, worktreePath: worktree.path) == workspace,
          !hasOpenWorkspaceDocuments
        else { return }
        presentedAlert = .returnRemoteWorkspace(repository, worktree, workspace, preparation)
      } catch {
        show(error)
      }
    }
  }

  func confirmReturnRemoteWorkspace(
    repository: RepositoryRecord,
    worktree: GitWorktree,
    workspace: RemoteWorkspaceRecord,
    preparation: RemoteReturnPreparation
  ) {
    let currentSessionIDs = Set(
      terminals(repositoryID: repository.id, worktreePath: worktree.path).map(\.tmuxSessionID)
    )
    guard !isBusy, !hasOpenWorkspaceDocuments,
      remoteWorkspace(repositoryID: repository.id, worktreePath: worktree.path) == workspace,
      workspace.isRemoteAuthoritative,
      currentSessionIDs.isSubset(of: Set(preparation.recordedSessionIDs))
    else {
      presentedAlert = .error(
        "The workspace or its terminal records changed after verification. Nothing was returned; "
          + "start again so Feather can capture a fresh checkpoint."
      )
      return
    }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let returned = try await remoteReturnService.returnWorkspace(
          workspace,
          to: worktree.path,
          preparation: preparation
        )
        let workspaceTerminals = terminals.filter {
          workspace.matches(repositoryID: $0.repositoryID, worktreePath: $0.worktreePath)
        }
        for terminal in workspaceTerminals {
          terminalRegistry.release(terminal.id)
          terminalRuntimeStates.removeValue(forKey: terminal.id)
          terminalRuntimeAgentKinds.removeValue(forKey: terminal.id)
          observedTerminalRuntimeIDs.remove(terminal.id)
          acknowledgedAgentResponses.remove(terminal.id)
        }
        let removedTerminalIDs = Set(workspaceTerminals.map(\.id))
        terminals.removeAll { removedTerminalIDs.contains($0.id) }
        if selectedTerminalID.map(removedTerminalIDs.contains) == true {
          selectedTerminalID = nil
        }
        let returnedWorkspace = workspace.recordingReturn(returned)
        if let index = remoteWorkspaces.firstIndex(where: { $0.id == workspace.id }) {
          remoteWorkspaces[index] = returnedWorkspace
        } else {
          remoteWorkspaces.append(returnedWorkspace)
        }
        remoteWorkspaceRuntimeStates.removeValue(forKey: workspace.id)
        persist()
        updateTerminalMonitor()
        presentedAlert = .message(
          "Workspace Returned",
          "The verified remote Git state is now local. Feather ended its recorded remote sessions "
            + "and kept the owned remote checkout until you explicitly clean it up."
        )
      } catch {
        show(error)
      }
    }
  }

  func requestCleanupSelectedRemoteWorkspace() {
    guard let workspace = selectedRemoteWorkspace else { return }
    requestCleanupRemoteWorkspace(workspace)
  }

  func requestCleanupRemoteWorkspace(_ workspace: RemoteWorkspaceRecord) {
    guard !isBusy, workspace.returned != nil,
      remoteWorkspaces.contains(where: { $0 == workspace })
    else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let preflight = try await remoteReturnService.cleanupPreflight(workspace: workspace)
        guard remoteWorkspaces.contains(where: { $0 == workspace }) else { return }
        presentedAlert = .cleanupRemoteWorkspace(workspace, preflight)
      } catch {
        show(error)
      }
    }
  }

  func confirmCleanupRemoteWorkspace(
    _ workspace: RemoteWorkspaceRecord,
    preflight: RemoteCleanupPreflight
  ) {
    guard !isBusy, workspace.returned != nil,
      remoteWorkspaces.contains(where: { $0 == workspace })
    else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        try await remoteReturnService.cleanupWorkspace(
          workspace,
          endingActiveSessions: preflight.activeSessionCount > 0
        )
        remoteWorkspaces.removeAll { $0.id == workspace.id }
        remoteWorkspaceRuntimeStates.removeValue(forKey: workspace.id)
        persist()
        presentedAlert = .message(
          "Remote Copy Removed",
          "Feather verified ownership and removed only its recorded checkout on "
            + "\(workspace.profileName)."
        )
      } catch {
        show(error)
      }
    }
  }

  func reconnectSelectedRemoteWorkspace() {
    guard canReconnectSelectedRemoteWorkspace,
      let workspace = selectedAuthoritativeRemoteWorkspace
    else {
      return
    }
    reconnectRemoteWorkspace(workspace)
  }

  func reconnectRemoteWorkspace(_ workspace: RemoteWorkspaceRecord) {
    guard !isBusy, workspace.isRemoteAuthoritative,
      remoteWorkspaces.contains(where: { $0 == workspace })
    else { return }
    isBusy = true
    remoteWorkspaceRuntimeStates[workspace.id] = .connecting
    Task {
      defer { isBusy = false }
      do {
        let state = try await reconcileRemoteWorkspace(workspace)
        switch state {
        case .connected:
          presentedAlert = .message("Remote Workspace Connected", workspace.profileName)
        case .offline:
          presentedAlert = .message(
            "Remote Workspace Offline",
            "Feather kept the workspace and session records. Try reconnecting when \(workspace.profileName) is reachable."
          )
        case .ownershipMismatch:
          presentedAlert = .error(
            "The remote ownership marker no longer matches. Feather kept the record and will not modify the checkout."
          )
        case .connecting:
          break
        }
      } catch {
        applyRemoteWorkspaceState(.offline, to: workspace)
        show(error)
      }
    }
  }

  func toggleSidebar() {
    sidebarVisible.toggle()
    persist()
  }

  func toggleInspector() {
    inspectorVisible.toggle()
    persist()
  }

  private func closeTerminal(_ terminal: TerminalRecord) async {
    guard let backend = terminalBackend(for: terminal) else {
      show(FeatherError.tmuxUnavailable)
      return
    }
    do {
      try await backend.killSession(terminal.tmuxSessionID)
    } catch {
      markRemoteWorkspaceOfflineIfNeeded(error, for: terminal)
      show(error)
      return
    }
    terminalRegistry.release(terminal.id)
    terminals.removeAll { $0.id == terminal.id }
    terminalRuntimeStates.removeValue(forKey: terminal.id)
    terminalRuntimeAgentKinds.removeValue(forKey: terminal.id)
    observedTerminalRuntimeIDs.remove(terminal.id)
    acknowledgedAgentResponses.remove(terminal.id)
    if selectedTerminalID == terminal.id {
      selectedTerminalID = selectedWorktreeTerminals.first?.id
    }
    persist()
    updateTerminalMonitor()
  }

  private func removeProject(
    _ repository: RepositoryRecord,
    deleteManagedWorktrees: Bool
  ) async {
    guard repositories.contains(where: { $0.id == repository.id }) else { return }
    isBusy = true
    defer { isBusy = false }

    do {
      if let workspace = remoteWorkspaces.first(where: { $0.repositoryID == repository.id }) {
        throw FeatherError.remoteWorkspaceActive(workspace.worktreePath)
      }
      let ownedPaths = Set(
        managedWorktrees
          .filter { $0.repositoryID == repository.id }
          .map(\.path)
      )
      var liveOwnedPaths: [String] = []
      if deleteManagedWorktrees {
        let currentWorktrees = try await gitService.listWorktrees(
          repositoryPath: repository.path
        )
        liveOwnedPaths =
          currentWorktrees
          .filter { $0.path != repository.path && ownedPaths.contains($0.path) }
          .map(\.path)
        for path in liveOwnedPaths {
          guard try await gitService.isClean(worktreePath: path) else {
            throw FeatherError.dirtyWorktree(path)
          }
        }
      }

      try await terminateTerminals(repositoryID: repository.id)

      if deleteManagedWorktrees {
        for path in liveOwnedPaths {
          try await gitService.removeWorktree(
            repositoryPath: repository.path,
            worktreePath: path
          )
        }
      }

      managedWorktrees.removeAll { $0.repositoryID == repository.id }
      repositories.removeAll { $0.id == repository.id }
      worktreesByRepository.removeValue(forKey: repository.id)
      if selectedRepositoryID == repository.id {
        selectedRepositoryID = nil
        selectedWorktreePath = nil
        selectedTerminalID = nil
      }
      reconcileSelection()
    } catch {
      if let worktrees = try? await gitService.listWorktrees(repositoryPath: repository.path) {
        worktreesByRepository[repository.id] = worktrees
        let livePaths = Set(worktrees.map(\.path))
        managedWorktrees.removeAll {
          $0.repositoryID == repository.id && !livePaths.contains($0.path)
        }
      }
      persist()
      show(error)
    }
  }

  private func terminateTerminals(repositoryID: UUID, worktreePath: String? = nil) async throws {
    let projectTerminals = terminals.filter {
      $0.repositoryID == repositoryID
        && (worktreePath == nil || $0.worktreePath == worktreePath)
    }
    for terminal in projectTerminals {
      guard let backend = terminalBackend(for: terminal) else {
        throw FeatherError.tmuxUnavailable
      }
      try await backend.killSession(terminal.tmuxSessionID)
      terminalRegistry.release(terminal.id)
    }
    let terminatedIDs = Set(projectTerminals.map(\.id))
    terminals.removeAll { terminatedIDs.contains($0.id) }
    for terminal in projectTerminals {
      terminalRuntimeStates.removeValue(forKey: terminal.id)
      terminalRuntimeAgentKinds.removeValue(forKey: terminal.id)
      observedTerminalRuntimeIDs.remove(terminal.id)
      acknowledgedAgentResponses.remove(terminal.id)
    }
    updateTerminalMonitor()
  }

  private func updateWorktree(_ worktree: GitWorktree, repositoryID: UUID) {
    if let index = worktreesByRepository[repositoryID]?.firstIndex(where: {
      $0.path == worktree.path
    }) {
      worktreesByRepository[repositoryID]?[index] = worktree
    } else {
      worktreesByRepository[repositoryID, default: []].append(worktree)
    }
  }

  private func setManagedWorktreeState(
    _ state: ManagedWorktreeState,
    repositoryID: UUID,
    path: String
  ) {
    guard
      let index = managedWorktrees.firstIndex(where: {
        $0.repositoryID == repositoryID && $0.path == path
      })
    else { return }
    managedWorktrees[index].state = state
  }

  private func reconcileSelection() {
    if selectedPendingWorktree != nil { return }
    if let repositoryID = selectedRepositoryID,
      let path = selectedWorktreePath,
      worktreesByRepository[repositoryID]?.contains(where: { $0.path == path }) == true
    {
      if !selectedWorktreeTerminals.contains(where: { $0.id == selectedTerminalID }) {
        selectedTerminalID = selectedWorktreeTerminals.first?.id
      }
      persist()
      return
    }

    guard let repository = repositories.first,
      let worktree = worktreesByRepository[repository.id]?.first
    else {
      selectedRepositoryID = nil
      selectedWorktreePath = nil
      selectedTerminalID = nil
      persist()
      return
    }
    selectWorktree(repositoryID: repository.id, path: worktree.path)
  }

  private func persist() {
    let snapshot = ApplicationSnapshot(
      repositories: repositories,
      managedWorktrees: managedWorktrees,
      terminals: terminals,
      appearance: appearance,
      selectedRepositoryID: selectedRepositoryID,
      selectedWorktreePath: selectedWorktreePath,
      selectedTerminalID: selectedTerminalID,
      sidebarVisible: sidebarVisible,
      inspectorVisible: inspectorVisible,
      remoteTarget: remoteTarget,
      remoteProfiles: remoteProfiles,
      selectedRemoteProfileID: selectedRemoteProfileID,
      remoteWorkspaces: remoteWorkspaces
    )
    try? stateStore.save(snapshot)
  }

  private func show(_ error: Error) {
    presentedAlert = .error(error.localizedDescription)
  }

  private func terminalBackend(for terminal: TerminalRecord) -> (any TerminalBackend)? {
    if let workspace = remoteWorkspace(for: terminal),
      remoteWorkspaceRuntimeStates[workspace.id] != .connected
    {
      return nil
    }
    return switch executionTarget(for: terminal) {
    case .local:
      tmuxBackend
    case .ssh(let remote):
      SSHTmuxBackend(remote: remote)
    }
  }

  private func terminalWorkingDirectory(_ terminal: TerminalRecord) -> String {
    switch executionTarget(for: terminal) {
    case .local: terminal.worktreePath
    case .ssh(let remote): remote.workingDirectory
    }
  }

  private func ensureTerminalMonitorSession() async {
    guard let tmuxBackend,
      let terminal = terminals.first(where: { terminal in
        terminal.id == selectedTerminalID && executionTarget(for: terminal) == .local
      }) ?? terminals.first(where: { executionTarget(for: $0) == .local })
    else { return }
    try? await tmuxBackend.ensureSession(
      terminal.tmuxSessionID,
      workingDirectory: terminal.worktreePath
    )
  }

  private func acknowledgeAttentionIfNeeded(_ terminalID: UUID?) {
    guard let terminalID, terminalRuntimeStates[terminalID] == .attention,
      let terminal = terminals.first(where: { $0.id == terminalID })
    else { return }

    acknowledgedAgentResponses.insert(terminalID)
    terminalRuntimeStates[terminalID] = .running
    switch executionTarget(for: terminal) {
    case .local:
      guard let tmuxBackend else { return }
      Task {
        try? await tmuxBackend.acknowledgeAttention(sessionID: terminal.tmuxSessionID)
        await refreshLocalTerminalStates()
      }
    case .ssh(let remote):
      let backend = SSHTmuxBackend(remote: remote)
      Task {
        do {
          try await backend.acknowledgeAttention(sessionID: terminal.tmuxSessionID)
          guard terminals.contains(where: { $0.id == terminalID }) else { return }
          if let command = try await backend.foregroundCommand(terminal.tmuxSessionID) {
            terminalRuntimeStates[terminalID] =
              TmuxSessionRuntimeSnapshot(
                sessionID: terminal.tmuxSessionID,
                command: command,
                paneDead: false,
                hasBell: false
              ).state
          } else {
            terminalRuntimeStates[terminalID] = .exited
          }
        } catch {
          markRemoteWorkspaceOfflineIfNeeded(error, for: terminal)
        }
      }
    }
  }

  private func updateTerminalMonitor() {
    guard !terminals.isEmpty else {
      terminalMonitorTask?.cancel()
      terminalMonitorTask = nil
      return
    }
    guard terminalMonitorTask == nil else { return }
    terminalMonitorTask = Task { [weak self] in
      guard let self else { return }
      var pollCount = 0
      while !Task.isCancelled {
        await refreshLocalTerminalStates()
        if pollCount.isMultiple(of: 3) {
          await refreshConnectedRemoteTerminalStates()
        }
        pollCount += 1
        do {
          try await Task.sleep(for: .seconds(2))
        } catch {
          break
        }
      }
      terminalMonitorTask = nil
    }
  }

  private func refreshLocalTerminalStates() async {
    guard let tmuxBackend, let snapshots = try? await tmuxBackend.runtimeSnapshots() else { return }
    let bySession = Dictionary(grouping: snapshots, by: \.sessionID)
    for terminal in terminals {
      guard case .local = executionTarget(for: terminal) else { continue }
      guard let sessionSnapshots = bySession[terminal.tmuxSessionID] else {
        clearRuntimeAgentObservation(for: terminal.id)
        setTerminalRuntimeState(.exited, for: terminal.id)
        continue
      }
      observeRuntimeAgent(for: terminal.id, in: sessionSnapshots)
      let isSelected = selectedTerminalID == terminal.id && NSApp.isActive
      let reportedState = TmuxSessionRuntimeResolver.state(
        for: terminal.tmuxSessionID,
        in: sessionSnapshots
      )
      if reportedState == .attention, isSelected {
        try? await tmuxBackend.acknowledgeAttention(sessionID: terminal.tmuxSessionID)
      }
      setTerminalRuntimeState(
        polledRuntimeState(
          for: terminal,
          snapshots: sessionSnapshots,
          reportedState: reportedState,
          isSelected: isSelected
        ),
        for: terminal.id
      )
    }
  }

  private func refreshConnectedRemoteTerminalStates() async {
    for workspace in remoteWorkspaces
    where workspace.isRemoteAuthoritative
      && remoteWorkspaceRuntimeStates[workspace.id] == .connected
    {
      do {
        _ = try await refreshRemoteTerminalStates(in: workspace)
      } catch {
        applyRemoteWorkspaceState(.offline, to: workspace)
      }
    }
  }

  private func observeRuntimeAgent(
    for terminalID: UUID,
    in snapshots: [TmuxSessionRuntimeSnapshot]
  ) {
    let previousKind = terminalRuntimeAgentKinds[terminalID]
    let kind = snapshots.compactMap(\.agentKind).first
    let wasObserved = observedTerminalRuntimeIDs.contains(terminalID)
    if !wasObserved || previousKind != kind {
      acknowledgedAgentResponses.remove(terminalID)
    }
    if !wasObserved {
      observedTerminalRuntimeIDs.insert(terminalID)
    }
    if let kind, previousKind != kind {
      terminalRuntimeAgentKinds[terminalID] = kind
    } else if kind == nil, previousKind != nil {
      terminalRuntimeAgentKinds.removeValue(forKey: terminalID)
    }
  }

  private func clearRuntimeAgentObservation(for terminalID: UUID) {
    if terminalRuntimeAgentKinds[terminalID] != nil {
      terminalRuntimeAgentKinds.removeValue(forKey: terminalID)
    }
    if observedTerminalRuntimeIDs.contains(terminalID) {
      observedTerminalRuntimeIDs.remove(terminalID)
    }
    acknowledgedAgentResponses.remove(terminalID)
  }

  private func setTerminalRuntimeState(
    _ state: TerminalRuntimeState,
    for terminalID: UUID
  ) {
    guard terminalRuntimeStates[terminalID] != state else { return }
    terminalRuntimeStates[terminalID] = state
  }

  private func polledRuntimeState(
    for terminal: TerminalRecord,
    snapshots: [TmuxSessionRuntimeSnapshot],
    reportedState: TerminalRuntimeState,
    isSelected: Bool
  ) -> TerminalRuntimeState {
    let clearedSnapshots = snapshots.map {
      TmuxSessionRuntimeSnapshot(
        sessionID: $0.sessionID,
        command: $0.command,
        paneDead: $0.paneDead,
        hasBell: false,
        title: $0.title
      )
    }
    let stateWithoutAttention = TmuxSessionRuntimeResolver.state(
      for: terminal.tmuxSessionID,
      in: clearedSnapshots
    )
    let decision = PolledTerminalRuntimePolicy.decide(
      reportedState: reportedState,
      stateWithoutAttention: stateWithoutAttention,
      agentActivity: TmuxSessionRuntimeResolver.agentActivity(
        for: terminal.tmuxSessionID,
        in: snapshots
      ),
      isSelected: isSelected,
      responseAcknowledged: acknowledgedAgentResponses.contains(terminal.id)
    )
    switch decision.acknowledgement {
    case .keep:
      break
    case .record:
      acknowledgedAgentResponses.insert(terminal.id)
    case .clear:
      acknowledgedAgentResponses.remove(terminal.id)
    }
    return decision.state
  }

  private func refreshRemoteWorkspaceStates() async {
    for workspace in remoteWorkspaces where workspace.isRemoteAuthoritative {
      remoteWorkspaceRuntimeStates[workspace.id] = .connecting
      do {
        _ = try await reconcileRemoteWorkspace(workspace)
      } catch {
        applyRemoteWorkspaceState(.offline, to: workspace)
      }
    }
  }

  @discardableResult
  private func reconcileRemoteWorkspace(
    _ workspace: RemoteWorkspaceRecord,
    afterAttachmentExit terminalID: UUID? = nil
  ) async throws -> RemoteWorkspaceRuntimeState {
    let state = try await remoteHandoffService.checkWorkspace(workspace)
    guard state == .connected else {
      applyRemoteWorkspaceState(state, to: workspace)
      return state
    }

    let snapshots = try await refreshRemoteTerminalStates(in: workspace)
    if let terminalID, let terminal = terminals.first(where: { $0.id == terminalID }) {
      let postExitState = RemoteWorkspaceRuntimePolicy.stateAfterAttachmentExit(
        sessionID: terminal.tmuxSessionID,
        snapshots: snapshots
      )
      if postExitState == .offline {
        applyRemoteWorkspaceState(postExitState, to: workspace)
        return postExitState
      }
    }
    applyRemoteWorkspaceState(.connected, to: workspace)
    return .connected
  }

  private func refreshRemoteTerminalStates(
    in workspace: RemoteWorkspaceRecord
  ) async throws -> [TmuxSessionRuntimeSnapshot] {
    let workspaceTerminals = terminals.filter {
      workspace.matches(repositoryID: $0.repositoryID, worktreePath: $0.worktreePath)
    }
    guard !workspaceTerminals.isEmpty else { return [] }

    let backend = SSHTmuxBackend(remote: workspace.remote)
    let snapshots = try await backend.runtimeSnapshots()
    let bySession = Dictionary(grouping: snapshots, by: \.sessionID)
    for terminal in workspaceTerminals {
      guard terminals.contains(where: { $0.id == terminal.id }) else { continue }
      guard let sessionSnapshots = bySession[terminal.tmuxSessionID] else {
        clearRuntimeAgentObservation(for: terminal.id)
        setTerminalRuntimeState(.exited, for: terminal.id)
        continue
      }
      observeRuntimeAgent(for: terminal.id, in: sessionSnapshots)
      let isSelected = selectedTerminalID == terminal.id && NSApp.isActive
      let reportedState = TmuxSessionRuntimeResolver.state(
        for: terminal.tmuxSessionID,
        in: sessionSnapshots
      )
      if reportedState == .attention, isSelected {
        try await backend.acknowledgeAttention(sessionID: terminal.tmuxSessionID)
      }
      setTerminalRuntimeState(
        polledRuntimeState(
          for: terminal,
          snapshots: sessionSnapshots,
          reportedState: reportedState,
          isSelected: isSelected
        ),
        for: terminal.id
      )
    }
    return snapshots
  }

  private func refreshSelectedRemoteTerminalStatesIfNeeded() {
    guard let workspace = selectedAuthoritativeRemoteWorkspace,
      remoteWorkspaceRuntimeStates[workspace.id] == .connected
    else { return }
    Task {
      do {
        _ = try await refreshRemoteTerminalStates(in: workspace)
      } catch {
        applyRemoteWorkspaceState(.offline, to: workspace)
      }
    }
  }

  private func applyRemoteWorkspaceState(
    _ state: RemoteWorkspaceRuntimeState,
    to workspace: RemoteWorkspaceRecord
  ) {
    remoteWorkspaceRuntimeStates[workspace.id] = state
    let workspaceTerminals = terminals.filter {
      workspace.matches(repositoryID: $0.repositoryID, worktreePath: $0.worktreePath)
    }
    for terminal in workspaceTerminals {
      terminalRegistry.release(terminal.id)
      switch state {
      case .connected:
        if terminalRuntimeStates[terminal.id] == .offline {
          terminalRuntimeStates[terminal.id] =
            AgentKind(terminal: terminal) == nil ? .shell : .running
        }
      case .offline, .ownershipMismatch:
        terminalRuntimeStates[terminal.id] = .offline
      case .connecting:
        break
      }
    }
  }

  private func markRemoteWorkspaceConnected(for terminal: TerminalRecord) {
    guard let workspace = remoteWorkspace(for: terminal) else { return }
    remoteWorkspaceRuntimeStates[workspace.id] = .connected
  }

  private func markRemoteWorkspaceOfflineIfNeeded(_ error: Error, for terminal: TerminalRecord) {
    guard let workspace = remoteWorkspace(for: terminal) else { return }
    if let failure = error as? BoundedCommandFailure, failure.status == 255 {
      applyRemoteWorkspaceState(.offline, to: workspace)
    } else if let boundedError = error as? BoundedCommandError,
      case .timedOut = boundedError
    {
      applyRemoteWorkspaceState(.offline, to: workspace)
    }
  }

  private func handleTerminalRuntimeEvent(
    terminalID: UUID,
    event: TerminalSurfaceRuntimeEvent
  ) {
    guard let terminal = terminals.first(where: { $0.id == terminalID }) else { return }
    switch event {
    case .running:
      acknowledgedAgentResponses.remove(terminalID)
      terminalRuntimeStates[terminalID] = .running
    case .attention:
      if selectedTerminalID == terminalID, NSApp.isActive {
        terminalRuntimeStates[terminalID] = .attention
        acknowledgeAttentionIfNeeded(terminalID)
      } else {
        terminalRuntimeStates[terminalID] = .attention
      }
    case .commandFinished:
      terminalRuntimeStates[terminalID] =
        selectedTerminalID == terminalID && NSApp.isActive ? .shell : .attention
    case .exited:
      guard let workspace = remoteWorkspace(for: terminal) else {
        terminalRuntimeStates[terminalID] = .exited
        return
      }
      guard remoteWorkspaceRuntimeStates[workspace.id] == .connected else { return }
      remoteWorkspaceRuntimeStates[workspace.id] = .connecting
      Task {
        do {
          _ = try await reconcileRemoteWorkspace(
            workspace,
            afterAttachmentExit: terminalID
          )
        } catch {
          applyRemoteWorkspaceState(.offline, to: workspace)
        }
      }
    }
  }
}
