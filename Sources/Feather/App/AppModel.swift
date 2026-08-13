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

@MainActor
final class AppModel: ObservableObject {
  enum PresentedAlert: Identifiable {
    case error(String)
    case closeTerminal(TerminalRecord, String)
    case closePane(TerminalRecord, TerminalPaneState)
    case removeWorktree(RepositoryRecord, GitWorktree)
    case returnWorktree(RepositoryRecord, GitWorktree)

    var id: String {
      switch self {
      case .error(let message): "error-\(message)"
      case .closeTerminal(let terminal, _): "terminal-\(terminal.id)"
      case .closePane(_, let pane): "pane-\(pane.id)"
      case .removeWorktree(_, let worktree): "worktree-\(worktree.path)"
      case .returnWorktree(_, let worktree): "return-\(worktree.path)"
      }
    }
  }

  @Published private(set) var repositories: [RepositoryRecord]
  @Published private(set) var worktreesByRepository: [UUID: [GitWorktree]] = [:]
  @Published private(set) var managedWorktrees: [ManagedWorktreeRecord]
  @Published private(set) var terminals: [TerminalRecord]
  @Published private(set) var pendingWorktree: WorktreeCreation?
  @Published private(set) var selectedPendingWorktreeID: UUID?
  @Published var selectedRepositoryID: UUID?
  @Published var selectedWorktreePath: String?
  @Published var selectedTerminalID: UUID?
  @Published var sidebarVisible: Bool
  @Published var inspectorVisible: Bool
  @Published var isBusy = false
  @Published var presentedAlert: PresentedAlert?
  @Published var projectRemovalCandidate: RepositoryRecord?
  @Published var appearance: AppearancePreference {
    didSet {
      guard oldValue != appearance else { return }
      terminalRegistry.updateAppearance(appearance)
      persist()
    }
  }

  let stateStore: JSONStateStore
  let gitService = GitService()
  let tmuxBackend: TmuxBackend?
  let tmuxSpec: TmuxLaunchSpec?
  let terminalRegistry: TerminalRegistry
  let worktreesRoot: URL
  private var hasStarted = false

  init() {
    let fallbackSupport = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Feather", isDirectory: true)
    let applicationSupportURL =
      (try? JSONStateStore.applicationSupportURL()) ?? fallbackSupport
    stateStore = JSONStateStore(fileURL: applicationSupportURL.appendingPathComponent("state.json"))
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
    worktreesRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Developer/Worktrees", isDirectory: true)

    let preparedSpec = try? TmuxEnvironment.prepare(applicationSupportURL: applicationSupportURL)
    tmuxSpec = preparedSpec
    tmuxBackend = preparedSpec.map { TmuxBackend(spec: $0) }
    terminalRegistry = TerminalRegistry(
      applicationSupportURL: applicationSupportURL,
      launchSpec: preparedSpec
    )
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

  var canCreateTerminal: Bool {
    selectedWorktree != nil && selectedManagedWorktreeState != .available
  }

  var selectedWorktreeTerminals: [TerminalRecord] {
    guard let selectedRepositoryID, let selectedWorktreePath else { return [] }
    return terminals(repositoryID: selectedRepositoryID, worktreePath: selectedWorktreePath)
  }

  var setupError: String? {
    if tmuxSpec == nil { return FeatherError.tmuxUnavailable.localizedDescription }
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

  func moveRepositoryToTop(_ repository: RepositoryRecord) {
    guard let index = repositories.firstIndex(where: { $0.id == repository.id }), index > 0 else {
      return
    }
    let moved = repositories.remove(at: index)
    repositories.insert(moved, at: 0)
    persist()
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
    persist()
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
    persist()
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
    guard tmuxSpec != nil else {
      presentedAlert = .error(FeatherError.tmuxUnavailable.localizedDescription)
      return
    }
    let command = launch.command
    let terminal = makeTerminal(
      repositoryID: repositoryID,
      worktreePath: worktreePath,
      title: command == nil ? nil : launch.title
    )
    guard let command, let tmuxBackend else {
      addTerminal(terminal)
      return
    }

    isBusy = true
    Task {
      var launchError: Error?
      do {
        try await tmuxBackend.launchCommand(
          command,
          sessionID: terminal.tmuxSessionID,
          workingDirectory: terminal.worktreePath
        )
      } catch {
        launchError = error
      }
      addTerminal(terminal)
      isBusy = false
      if let launchError {
        show(launchError)
      }
    }
  }

  func splitTerminal(_ direction: TerminalSplitDirection) {
    guard let terminal = selectedTerminal, let tmuxBackend else { return }
    Task {
      do {
        try await tmuxBackend.splitPane(
          sessionID: terminal.tmuxSessionID,
          workingDirectory: terminal.worktreePath,
          direction: direction
        )
      } catch {
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
    selectedTerminalID = terminal.id
    persist()
  }

  func requestCloseTerminal(_ id: UUID? = nil, requiresConfirmation: Bool = true) {
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
          try await tmuxBackend?.foregroundCommand(terminal.tmuxSessionID) ?? "terminal process"
        presentedAlert = .closeTerminal(terminal, command)
      } catch {
        show(error)
      }
    }
  }

  func requestCloseContext() {
    guard let terminal = selectedTerminal, let tmuxBackend else {
      requestCloseTerminal()
      return
    }
    Task {
      do {
        guard let pane = try await tmuxBackend.activePane(terminal.tmuxSessionID) else {
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
    guard let tmuxBackend else { return }
    Task {
      do {
        guard try await tmuxBackend.killPane(pane.id, sessionID: terminal.tmuxSessionID) else {
          presentedAlert = .error("That pane changed. Press ⌘W again to close the active pane.")
          return
        }
      } catch {
        show(error)
      }
    }
  }

  func requestRemoveWorktree(repository: RepositoryRecord, worktree: GitWorktree) {
    guard isManagedWorktree(repositoryID: repository.id, path: worktree.path) else {
      presentedAlert = .error(FeatherError.unmanagedWorktreeRemoval.localizedDescription)
      return
    }
    let activeCount = terminals.filter {
      $0.repositoryID == repository.id && $0.worktreePath == worktree.path
    }.count
    guard activeCount == 0 else {
      presentedAlert = .error(FeatherError.activeTerminals(activeCount).localizedDescription)
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
        presentedAlert = .removeWorktree(repository, worktree)
      } catch {
        show(error)
      }
    }
  }

  func confirmRemoveWorktree(repository: RepositoryRecord, worktree: GitWorktree) {
    Task {
      isBusy = true
      defer { isBusy = false }
      do {
        try await gitService.removeWorktree(
          repositoryPath: repository.path,
          worktreePath: worktree.path
        )
        worktreesByRepository[repository.id]?.removeAll { $0.path == worktree.path }
        managedWorktrees.removeAll {
          $0.repositoryID == repository.id && $0.path == worktree.path
        }
        reconcileSelection()
      } catch {
        show(error)
      }
    }
  }

  func requestReturnWorktree(repository: RepositoryRecord, worktree: GitWorktree) {
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

  func toggleSidebar() {
    sidebarVisible.toggle()
    persist()
  }

  func toggleInspector() {
    inspectorVisible.toggle()
    persist()
  }

  private func closeTerminal(_ terminal: TerminalRecord) async {
    if let tmuxBackend {
      try? await tmuxBackend.killSession(terminal.tmuxSessionID)
    }
    terminalRegistry.release(terminal.id)
    terminals.removeAll { $0.id == terminal.id }
    if selectedTerminalID == terminal.id {
      selectedTerminalID = selectedWorktreeTerminals.first?.id
    }
    persist()
  }

  private func removeProject(
    _ repository: RepositoryRecord,
    deleteManagedWorktrees: Bool
  ) async {
    guard repositories.contains(where: { $0.id == repository.id }) else { return }
    isBusy = true
    defer { isBusy = false }

    do {
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

      await terminateTerminals(repositoryID: repository.id)

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

  private func terminateTerminals(repositoryID: UUID) async {
    let projectTerminals = terminals.filter { $0.repositoryID == repositoryID }
    for terminal in projectTerminals {
      if let tmuxBackend {
        try? await tmuxBackend.killSession(terminal.tmuxSessionID)
      }
      terminalRegistry.release(terminal.id)
    }
    terminals.removeAll { $0.repositoryID == repositoryID }
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
      inspectorVisible: inspectorVisible
    )
    try? stateStore.save(snapshot)
  }

  private func show(_ error: Error) {
    presentedAlert = .error(error.localizedDescription)
  }
}
