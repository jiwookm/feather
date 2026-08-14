import FeatherCore
import SwiftUI

struct TerminalWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openSettings) private var openSettings
  @State private var terminalLauncherPresented = false
  let isFullScreen: Bool

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      tabBar

      if model.selectedPendingWorktree != nil {
        worktreeCreatingView
      } else if let setupError = model.setupError {
        setupErrorView(setupError)
      } else if model.selectedWorktree == nil {
        noWorktreeView
      } else if model.selectedManagedWorktreeState == .available {
        availableWorktreeView
      } else if let remoteState = selectedRemoteBlockingState {
        remoteBlockingView(remoteState)
      } else if let terminal = model.selectedTerminal {
        TerminalSurfaceContainer(terminal: terminal)
          .id(surfaceIdentity(terminal))
      } else {
        noTerminalView
      }
    }
    .background(palette.terminal)
    .confirmationDialog(
      "New Terminal",
      isPresented: $terminalLauncherPresented,
      titleVisibility: .visible
    ) {
      terminalLaunchChoices
    } message: {
      Text("Start an agent or open a shell in this worktree.")
    }
    .onReceive(NotificationCenter.default.publisher(for: .featherNewTerminalRequested)) { _ in
      presentTerminalLauncher()
    }
  }

  private var tabBar: some View {
    HStack(spacing: 0) {
      if !model.sidebarVisible {
        Button(action: model.toggleSidebar) {
          Image(systemName: "sidebar.left")
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(HoverButtonStyle())
        .help("Show Sidebar (⌘S)")
        .padding(.leading, isFullScreen ? 8 : 76)
        .padding(.trailing, 4)
      }

      ScrollView(.horizontal) {
        LazyHStack(spacing: 0) {
          ForEach(model.selectedWorktreeTerminals) { terminal in
            terminalTab(terminal)
          }

          Button(action: presentTerminalLauncher) {
            Image(systemName: "plus")
              .font(.system(size: 12, weight: .medium))
          }
          .buttonStyle(HoverButtonStyle())
          .disabled(!model.canCreateTerminal || model.isBusy)
          .padding(.horizontal, 6)
          .help("New Terminal… (⌘T)")
        }
      }
      .scrollIndicators(.never)

      Button(action: model.toggleInspector) {
        Image(systemName: "sidebar.right")
          .font(.system(size: 12, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .foregroundStyle(model.inspectorVisible ? palette.primaryText : palette.secondaryText)
      .padding(.leading, 5)
      .help("Toggle Inspector (⌘E)")

      Button(action: openSettings.callAsFunction) {
        Image(systemName: "gearshape")
          .font(.system(size: 12, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .padding(.leading, 4)
      .padding(.trailing, 8)
      .help("Settings… (⌘,)")
    }
    .frame(height: FeatherMetrics.titlebarHeight(isFullScreen))
    .background(palette.titlebar)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.border).frame(height: 1)
    }
    .background(WindowDragSurface())
  }

  private func terminalTab(_ terminal: TerminalRecord) -> some View {
    let selected = terminal.id == model.selectedTerminalID
    let runtimeState = model.runtimeState(for: terminal)
    return HStack(spacing: 8) {
      if let kind = AgentKind(terminal: terminal) {
        AgentIcon(
          kind: kind,
          size: 14,
          tint: selected ? palette.primaryText : palette.secondaryText
        )
      } else {
        Image(systemName: TerminalLaunch.terminal.systemImage)
          .font(.system(size: 11, weight: .medium))
      }
      if runtimeState.showsNotificationBadge {
        TerminalRuntimeBadge(state: runtimeState, size: 7)
      }
      Text(terminal.title)
        .font(.feather(size: 14, weight: selected ? .medium : .regular))
        .lineLimit(1)
      Button {
        model.requestCloseTerminal(terminal.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.secondaryText)
    }
    .foregroundStyle(selected ? palette.primaryText : palette.secondaryText)
    .padding(.horizontal, 12)
    .frame(height: FeatherMetrics.titlebarHeight(isFullScreen) - 1)
    .background(selected ? palette.terminal : .clear)
    .overlay(alignment: .trailing) {
      Rectangle().fill(palette.border).frame(width: 1)
    }
    .contentShape(Rectangle())
    .onTapGesture { model.selectTerminal(terminal.id) }
    .help(terminalHelp(terminal))
  }

  private var noWorktreeView: some View {
    emptyState(
      symbol: "folder.badge.plus",
      title: "Add a project",
      message:
        "Feather will show the project and its managed worktrees without scanning your disk."
    ) {
      Button("Add Project", action: model.chooseAndRegisterRepository)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }
  }

  private var selectedRemoteBlockingState: RemoteWorkspaceRuntimeState? {
    guard let workspace = model.selectedRemoteWorkspace else { return nil }
    let state = model.remoteWorkspaceRuntimeStates[workspace.id] ?? .connecting
    return state == .connected ? nil : state
  }

  private func remoteBlockingView(_ state: RemoteWorkspaceRuntimeState) -> some View {
    let connecting = state == .connecting
    let ownershipMismatch = state == .ownershipMismatch
    return emptyState(
      symbol: connecting
        ? "network" : (ownershipMismatch ? "exclamationmark.shield" : "network.slash"),
      title:
        connecting
        ? "Connecting to remote workspace"
        : (ownershipMismatch ? "Ownership check failed" : "Remote workspace offline"),
      message:
        connecting
        ? "Feather is verifying the saved checkout before attaching any terminal."
        : (ownershipMismatch
          ? "Feather kept the workspace record but will not operate on a checkout whose ownership marker changed."
          : "The remote checkout and tmux sessions were left untouched. Reconnect when the host is reachable.")
    ) {
      if connecting {
        ProgressView().controlSize(.small)
      } else {
        Button("Reconnect") { model.reconnectSelectedRemoteWorkspace() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(model.isBusy)
      }
    }
  }

  private var worktreeCreatingView: some View {
    emptyState(
      symbol: "arrow.triangle.2.circlepath",
      title: "Creating worktree",
      message: "Fetching the latest base and preparing the checkout."
    ) {
      ProgressView()
        .controlSize(.small)
    }
  }

  private var noTerminalView: some View {
    let remoteWorkspace = model.selectedRemoteWorkspace
    return emptyState(
      symbol: remoteWorkspace == nil ? "terminal" : "network",
      title: remoteWorkspace == nil ? "No terminals yet" : "Remote workspace ready",
      message:
        remoteWorkspace.map {
          "New terminals run on \($0.profileName) and reattach through its private tmux server."
        } ?? "Start an agent or open a persistent shell in this worktree."
    ) {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          terminalLaunchButton(.claude)
          terminalLaunchButton(.codex)
          terminalLaunchButton(.terminal)
        }
        if remoteWorkspace == nil, model.selectedRemoteProfile != nil {
          Button("Run Remotely…") { model.requestRunSelectedWorkspaceRemotely() }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!model.canRunSelectedWorkspaceRemotely)
        }
      }
    }
  }

  @ViewBuilder
  private var availableWorktreeView: some View {
    if let repository = model.selectedRepository, let worktree = model.selectedWorktree {
      emptyState(
        symbol: "arrow.triangle.2.circlepath",
        title: "Worktree available",
        message: "Reuse this checkout, or create a new worktree to claim it automatically."
      ) {
        Button("Reuse Worktree") {
          model.reuseWorktree(repository: repository, worktree: worktree)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(model.isBusy)
      }
    }
  }

  private func setupErrorView(_ message: String) -> some View {
    emptyState(
      symbol: "exclamationmark.triangle",
      title: "Terminal unavailable",
      message: message
    ) {
      EmptyView()
    }
  }

  private func emptyState<Actions: View>(
    symbol: String,
    title: String,
    message: String,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(palette.mutedText)
      Text(title)
        .font(.feather(size: 15, weight: .semibold))
        .foregroundStyle(palette.primaryText)
      Text(message)
        .font(.feather(size: 12))
        .foregroundStyle(palette.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
      actions()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.terminal)
  }

  @ViewBuilder
  private var terminalLaunchChoices: some View {
    Button {
      startTerminal(.claude)
    } label: {
      Label(TerminalLaunch.claude.title, systemImage: TerminalLaunch.claude.systemImage)
    }
    Button {
      startTerminal(.codex)
    } label: {
      Label(TerminalLaunch.codex.title, systemImage: TerminalLaunch.codex.systemImage)
    }
    Button {
      startTerminal(.terminal)
    } label: {
      Label(TerminalLaunch.terminal.title, systemImage: TerminalLaunch.terminal.systemImage)
    }
  }

  private func terminalLaunchButton(_ launch: TerminalLaunch) -> some View {
    Button {
      startTerminal(launch)
    } label: {
      Label(launch.title, systemImage: launch.systemImage)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(!model.canCreateTerminal || model.isBusy)
  }

  private func presentTerminalLauncher() {
    guard model.canCreateTerminal, !model.isBusy else { return }
    terminalLauncherPresented = true
  }

  private func startTerminal(_ launch: TerminalLaunch) {
    terminalLauncherPresented = false
    model.newTerminal(launch: launch)
  }

  private func surfaceIdentity(_ terminal: TerminalRecord) -> String {
    let state = model.remoteWorkspace(for: terminal).flatMap {
      model.remoteWorkspaceRuntimeStates[$0.id]
    }
    return switch model.executionTarget(for: terminal) {
    case .local:
      "\(terminal.id.uuidString)-local"
    case .ssh(let remote):
      "\(terminal.id.uuidString)-ssh-\(remote.target.host)-\(remote.workingDirectory)-\(state?.rawValue ?? "unknown")"
    }
  }

  private func terminalHelp(_ terminal: TerminalRecord) -> String {
    switch model.executionTarget(for: terminal) {
    case .local:
      terminal.worktreePath
    case .ssh(let remote):
      "\(remote.target.host):\(remote.workingDirectory)"
    }
  }
}

private struct TerminalSurfaceContainer: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let terminal: TerminalRecord
  @State private var handle: TerminalHandle?

  var body: some View {
    Group {
      if let handle {
        TerminalSurface(handle: handle)
      } else {
        ZStack {
          FeatherPalette(colorScheme: colorScheme).terminal
          ProgressView().controlSize(.small)
        }
      }
    }
    .task {
      handle = model.terminalRegistry.handle(
        for: terminal,
        executionTarget: model.executionTarget(for: terminal),
        appearance: model.appearance
      )
      if handle != nil {
        model.terminalSurfaceDidAttach(terminal)
      }
    }
    .onDisappear {
      handle = nil
      model.terminalRegistry.release(terminal.id)
    }
  }
}
