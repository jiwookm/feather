import AppKit
import FeatherCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  @State private var isFullScreen = false
  @State private var quickOpenVisible = false
  @State private var repositorySearchVisible = false
  @StateObject private var document = WorkspaceDocumentController()

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    dialogWorkspace
  }

  private var dialogWorkspace: some View {
    observedWorkspace
      .alert(item: $model.presentedAlert) { alert in
        makeAlert(for: alert)
      }
      .confirmationDialog(
        "Remove project from Feather?",
        isPresented: projectRemovalIsPresented,
        titleVisibility: .visible
      ) {
        if let repository = model.projectRemovalCandidate {
          Button("Remove Project, Keep Worktrees") {
            model.confirmRemoveProject(repository, deleteManagedWorktrees: false)
          }
          Button("Remove Project and Delete Feather Worktrees", role: .destructive) {
            model.confirmRemoveProject(repository, deleteManagedWorktrees: true)
          }
        }
        Button("Cancel", role: .cancel) {
          model.projectRemovalCandidate = nil
        }
      } message: {
        if let repository = model.projectRemovalCandidate {
          Text(projectRemovalMessage(for: repository))
        }
      }
  }

  private var observedWorkspace: some View {
    commandWorkspace
      .onChange(of: model.selectedWorktreePath) { _, selectedPath in
        if let request = document.request, request.rootPath != selectedPath {
          document.requestCloseAll()
        }
        quickOpenVisible = false
        repositorySearchVisible = false
      }
      .onChange(of: document.hasDocument) { _, hasDocument in
        model.updateWorkspaceDocumentState(hasOpenDocuments: hasDocument)
      }
      .onChange(of: model.isBusy) { _, isBusy in
        if isBusy {
          quickOpenVisible = false
          repositorySearchVisible = false
        }
      }
  }

  private var commandWorkspace: some View {
    windowAwareWorkspace
      .onReceive(NotificationCenter.default.publisher(for: .featherCloseTerminalRequested)) {
        notification in
        model.requestCloseTerminal(
          notification.userInfo?["terminalID"] as? UUID,
          requiresConfirmation: notification.userInfo?["requiresConfirmation"] as? Bool ?? true
        )
      }
      .onReceive(NotificationCenter.default.publisher(for: .featherCloseContextRequested)) { _ in
        if document.hasDocument {
          document.requestClose()
        } else {
          model.requestCloseContext()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .featherToggleSidebarRequested)) { _ in
        model.toggleSidebar()
      }
      .onReceive(NotificationCenter.default.publisher(for: .featherToggleInspectorRequested)) {
        _ in
        model.toggleInspector()
      }
      .onReceive(NotificationCenter.default.publisher(for: .featherQuickOpenRequested)) { _ in
        guard model.selectedWorktree != nil, model.selectedRemoteWorkspace == nil else { return }
        repositorySearchVisible = false
        quickOpenVisible.toggle()
      }
      .onReceive(NotificationCenter.default.publisher(for: .featherRepositorySearchRequested)) {
        _ in
        guard model.selectedWorktree != nil, model.selectedRemoteWorkspace == nil else { return }
        quickOpenVisible = false
        repositorySearchVisible.toggle()
      }
  }

  private var windowAwareWorkspace: some View {
    renderedWorkspace
      .task {
        model.updateWorkspaceDocumentState(hasOpenDocuments: document.hasDocument)
        model.start()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification))
    {
      notification in
      if notification.object as? NSWindow === FeatherWindow.workspace {
        isFullScreen = true
      }
    }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification))
    {
      notification in
      if notification.object as? NSWindow === FeatherWindow.workspace {
        isFullScreen = false
        DispatchQueue.main.async { FeatherWindow.alignWindowButtons() }
      }
    }
  }

  private var renderedWorkspace: some View {
    workspaceLayout
      .frame(minWidth: 820, minHeight: 520)
      .background(palette.terminal)
      .ignoresSafeArea(.container, edges: .top)
      .overlay { transientOverlay }
  }

  private var workspaceLayout: some View {
    HStack(spacing: 0) {
      if model.sidebarVisible {
        SidebarView(isFullScreen: isFullScreen)
          .frame(width: 252)
          .transition(.move(edge: .leading).combined(with: .opacity))

        Rectangle()
          .fill(palette.border)
          .frame(width: 1)
      }

      if document.hasDocument {
        WorkspaceDocumentView(controller: document, isFullScreen: isFullScreen)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        TerminalWorkspaceView(isFullScreen: isFullScreen)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if model.inspectorVisible {
        Rectangle()
          .fill(palette.border)
          .frame(width: 1)

        InspectorView(
          repository: model.selectedRepository,
          worktree: model.selectedWorktree,
          remoteWorkspace: model.selectedRemoteWorkspace,
          isFullScreen: isFullScreen,
          selectedDocumentPath: document.request?.path,
          onOpenFile: { path in
            guard let rootPath = model.selectedWorktree?.path else { return }
            document.openFile(rootPath: rootPath, path: path)
          },
          onOpenDiff: { file, staged in
            guard let rootPath = model.selectedWorktree?.path else { return }
            document.openDiff(rootPath: rootPath, file: file, staged: staged)
          },
          onOpenReviewDiff: { file, baseReference in
            guard let rootPath = model.selectedWorktree?.path else { return }
            document.openReviewDiff(
              rootPath: rootPath,
              file: file,
              baseReference: baseReference
            )
          }
        )
        .id(model.selectedWorktreePath)
        .frame(width: 288)
        .allowsHitTesting(!model.isBusy)
      }
    }
  }

  @ViewBuilder
  private var transientOverlay: some View {
    if quickOpenVisible, let rootPath = model.selectedWorktree?.path {
      QuickOpenView(
        rootPath: rootPath,
        onOpen: { path in
          document.openFile(rootPath: rootPath, path: path)
          quickOpenVisible = false
        },
        onDismiss: { quickOpenVisible = false }
      )
      .id(rootPath)
      .transition(.opacity)
    } else if repositorySearchVisible, let rootPath = model.selectedWorktree?.path {
      RepositorySearchView(
        rootPath: rootPath,
        onOpen: { match in
          let path = URL(fileURLWithPath: rootPath).appendingPathComponent(match.path).path
          document.openFile(rootPath: rootPath, path: path, line: match.line)
          repositorySearchVisible = false
        },
        onDismiss: { repositorySearchVisible = false }
      )
      .id(rootPath)
      .transition(.opacity)
    }
  }

  private func makeAlert(for alert: AppModel.PresentedAlert) -> Alert {
    switch alert {
    case .error(let message):
      Alert(
        title: Text("Feather"),
        message: Text(message),
        dismissButton: .default(Text("OK"))
      )
    case .message(let title, let message):
      Alert(
        title: Text(title),
        message: Text(message),
        dismissButton: .default(Text("OK"))
      )
    case .closeTerminal(let terminal, let command):
      Alert(
        title: Text("Close this terminal?"),
        message: Text(
          "`\(command)` is running in this tab. Closing it will terminate its tmux session."),
        primaryButton: .destructive(Text("Close")) {
          model.confirmCloseTerminal(terminal)
        },
        secondaryButton: .cancel()
      )
    case .closePane(let terminal, let pane):
      Alert(
        title: Text("Close this split pane?"),
        message: Text("`\(pane.command)` is running in this pane. Closing it will terminate it."),
        primaryButton: .destructive(Text("Close Pane")) {
          model.confirmClosePane(pane, in: terminal)
        },
        secondaryButton: .cancel()
      )
    case .removeWorktree(let repository, let worktree):
      Alert(
        title: Text("Remove \(worktree.displayName)?"),
        message: Text("The clean checkout will be removed. Its Git branch will be kept."),
        primaryButton: .destructive(Text("Remove Worktree")) {
          model.confirmRemoveWorktree(repository: repository, worktree: worktree)
        },
        secondaryButton: .cancel()
      )
    case .returnWorktree(let repository, let worktree):
      Alert(
        title: Text("Return \(worktree.displayName) for reuse?"),
        message: Text(
          "Feather will fetch the default branch, require a clean checkout with fully merged "
            + "work, and reset tracked files to that branch. Ignored dependencies and build "
            + "caches are kept."
        ),
        primaryButton: .default(Text("Return for Reuse")) {
          model.confirmReturnWorktree(repository: repository, worktree: worktree)
        },
        secondaryButton: .cancel()
      )
    case .runWorkspaceRemotely(let repository, let worktree, let profile):
      Alert(
        title: Text("Run \(worktree.displayName) on \(profile.name)?"),
        message: Text(
          "Feather will require a clean branch whose commit exactly matches origin, then create "
            + "an owned remote checkout and private tmux workspace. Every new terminal for this "
            + "worktree will run remotely."
        ),
        primaryButton: .default(Text("Run Remotely")) {
          model.confirmRunWorkspaceRemotely(
            repository: repository,
            worktree: worktree,
            profile: profile
          )
        },
        secondaryButton: .cancel()
      )
    }
  }

  private var projectRemovalIsPresented: Binding<Bool> {
    Binding(
      get: { model.projectRemovalCandidate != nil },
      set: { isPresented in
        if !isPresented {
          model.projectRemovalCandidate = nil
        }
      }
    )
  }

  private func projectRemovalMessage(for repository: RepositoryRecord) -> String {
    let worktreeCount = model.managedWorktreeCount(for: repository)
    let terminalCount = model.terminalCount(for: repository)
    let worktreeLabel = worktreeCount == 1 ? "worktree" : "worktrees"
    let terminalLabel = terminalCount == 1 ? "terminal session" : "terminal sessions"
    return
      "Feather created \(worktreeCount) \(worktreeLabel) and has \(terminalCount) "
      + "\(terminalLabel) for \(repository.displayName). Removing the project stops its terminal "
      + "sessions. You can keep every checkout or delete only clean worktrees created by "
      + "Feather. Git branches are always kept."
  }
}
