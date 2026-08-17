import AppKit
import FeatherCore
import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var avatars = RepositoryAvatarStore()
  @State private var collapsedRepositories: Set<UUID> = []
  let isFullScreen: Bool

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      sidebarTitlebar

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          workspaceHeader

          if model.repositories.isEmpty {
            emptyRepositories
          } else {
            ForEach(model.repositories) { repository in
              repositorySection(repository)
            }
          }

          if !orphanedRemoteWorkspaces.isEmpty {
            orphanedRemoteSection
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
      }
      .scrollIndicators(.never)

      if model.isBusy && model.pendingWorktree == nil {
        ProgressView()
          .controlSize(.small)
          .padding(.bottom, 10)
      }
    }
    .background(palette.sidebar)
    .onDisappear { avatars.cancel() }
  }

  private var sidebarTitlebar: some View {
    HStack(spacing: 12) {
      Text("Feather")
        .font(.feather(size: 15, weight: .semibold))
        .foregroundStyle(palette.primaryText)
      Button(action: model.toggleSidebar) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 13, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .help("Hide Sidebar (⌘S)")
      Spacer()
    }
    .padding(.leading, isFullScreen ? 16 : 76)
    .padding(.trailing, 8)
    .frame(height: FeatherMetrics.titlebarHeight(isFullScreen))
    .background(palette.titlebar)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.border).frame(height: 1)
    }
    .background(WindowDragSurface())
  }

  private var workspaceHeader: some View {
    HStack(spacing: 2) {
      Text("Projects")
        .font(.feather(size: 12, weight: .semibold))
        .foregroundStyle(palette.secondaryText)
      Spacer()
      Button(action: model.refresh) {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(HoverButtonStyle())
      .help("Refresh Worktrees (⌘R)")
      if let repository = model.selectedRepository {
        Button {
          model.createWorktree(for: repository)
        } label: {
          Image(systemName: "folder.badge.plus")
        }
        .buttonStyle(HoverButtonStyle())
        .help("New Worktree")
      } else {
        Button(action: model.chooseAndRegisterRepository) {
          Image(systemName: "folder.badge.plus")
        }
        .buttonStyle(HoverButtonStyle())
        .help("Add Project")
      }
      Button(action: model.chooseAndRegisterRepository) {
        Image(systemName: "plus")
      }
      .buttonStyle(HoverButtonStyle())
      .help("Add Project (⌘O)")
    }
    .font(.system(size: 11, weight: .medium))
    .frame(height: 22)
  }

  private var emptyRepositories: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("No projects")
        .font(.feather(size: 13, weight: .semibold))
        .foregroundStyle(palette.primaryText)
      Text("Add a Git project to create and manage Feather worktrees.")
        .font(.feather(size: 12))
        .foregroundStyle(palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      Button("Add Project", action: model.chooseAndRegisterRepository)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(12)
  }

  private var orphanedRemoteWorkspaces: [RemoteWorkspaceRecord] {
    model.remoteWorkspaces.filter { workspace in
      model.worktreesByRepository[workspace.repositoryID]?.contains(where: {
        $0.path == workspace.worktreePath
      }) != true
    }
  }

  private var orphanedRemoteSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Remote Records")
        .font(.feather(size: 11, weight: .semibold))
        .foregroundStyle(palette.mutedText)
        .padding(.horizontal, 8)

      ForEach(orphanedRemoteWorkspaces) { workspace in
        Button {
          model.selectWorktree(
            repositoryID: workspace.repositoryID,
            path: workspace.worktreePath
          )
        } label: {
          HStack(spacing: 8) {
            Image(
              systemName: orphanedRemoteSymbol(workspace)
            )
            .font(.system(size: 11, weight: .medium))
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
              Text(URL(fileURLWithPath: workspace.worktreePath).lastPathComponent)
                .font(.feather(size: 13, weight: .medium))
                .lineLimit(1)
              Text(orphanedRemoteSubtitle(workspace))
                .font(.feather(size: 10))
                .foregroundStyle(palette.mutedText)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
          }
          .foregroundStyle(palette.secondaryText)
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
          if workspace.isRemoteAuthoritative {
            Button("Reconnect Remote Workspace") {
              model.reconnectRemoteWorkspace(workspace)
            }
          } else {
            Button("Clean Up Remote Copy…") {
              model.requestCleanupRemoteWorkspace(workspace)
            }
          }
        }
        .help(workspace.remote.workingDirectory)
      }
    }
  }

  private func orphanedRemoteSymbol(_ workspace: RemoteWorkspaceRecord) -> String {
    guard workspace.isRemoteAuthoritative else { return "externaldrive.badge.checkmark" }
    return switch model.remoteWorkspaceRuntimeStates[workspace.id] ?? .connecting {
    case .connecting: "network"
    case .connected: "externaldrive.badge.exclamationmark"
    case .offline: "network.slash"
    case .ownershipMismatch: "exclamationmark.shield"
    }
  }

  private func orphanedRemoteSubtitle(_ workspace: RemoteWorkspaceRecord) -> String {
    guard workspace.isRemoteAuthoritative else { return "Returned · remote cleanup pending" }
    let state =
      switch model.remoteWorkspaceRuntimeStates[workspace.id] ?? .connecting {
      case .connecting: "Checking"
      case .connected: "Remote"
      case .offline: "Offline"
      case .ownershipMismatch: "Ownership mismatch"
      }
    return "\(state) · local checkout not listed · \(workspace.profileName)"
  }

  @ViewBuilder
  private func repositorySection(_ repository: RepositoryRecord) -> some View {
    let externalWorktrees = model.externalWorktrees(for: repository)
    let managedWorktrees = model.projectWorktrees(for: repository)
    let pendingWorktree = model.pendingCreation(for: repository)
    let isCollapsed = collapsedRepositories.contains(repository.id)
    let hasChildren = pendingWorktree != nil || !managedWorktrees.isEmpty
    let mainAgents = agentSessions(repositoryID: repository.id, worktreePath: repository.path)
    let mainRemoteWorkspace = model.remoteWorkspace(
      repositoryID: repository.id,
      worktreePath: repository.path
    )
    let mainSelected =
      model.selectedRepositoryID == repository.id
      && model.selectedWorktreePath == repository.path

    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Button {
          model.selectWorktree(repositoryID: repository.id, path: repository.path)
        } label: {
          HStack(spacing: 8) {
            RepositoryAvatarView(store: avatars, repository: repository)

            VStack(alignment: .leading, spacing: 2) {
              Text(repository.displayName)
                .font(.feather(size: 14, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)

              Text(repository.remoteDisplayName ?? "No origin remote")
                .font(.feather(size: 12))
                .foregroundStyle(palette.mutedText)
                .lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(repository.path)

        Spacer(minLength: 0)

        if !mainAgents.isEmpty {
          AgentSessionBadges(sessions: mainAgents)
        }

        if let mainRemoteWorkspace {
          Image(
            systemName: mainRemoteWorkspace.isRemoteAuthoritative
              ? "network" : "externaldrive.badge.checkmark"
          )
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(palette.secondaryText)
          .help(
            mainRemoteWorkspace.isRemoteAuthoritative
              ? "Runs remotely on \(mainRemoteWorkspace.profileName)"
              : "Returned locally; owned remote copy is retained for cleanup"
          )
        }

        if hasChildren {
          Button {
            if isCollapsed {
              collapsedRepositories.remove(repository.id)
            } else {
              collapsedRepositories.insert(repository.id)
            }
          } label: {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
              .font(.system(size: 10, weight: .semibold))
          }
          .buttonStyle(HoverButtonStyle())
          .help(isCollapsed ? "Show Worktrees" : "Hide Worktrees")
        }

        Menu {
          Button("New Worktree") {
            model.createWorktree(for: repository)
          }
          if mainRemoteWorkspace == nil {
            Button("Run Remotely…") {
              model.selectWorktree(repositoryID: repository.id, path: repository.path)
              model.requestRunSelectedWorkspaceRemotely()
            }
          } else if mainRemoteWorkspace?.isRemoteAuthoritative == true {
            Button("Reconnect Remote Workspace") {
              model.selectWorktree(repositoryID: repository.id, path: repository.path)
              model.reconnectSelectedRemoteWorkspace()
            }
            Button("Return Workspace to This Mac…") {
              model.selectWorktree(repositoryID: repository.id, path: repository.path)
              model.requestReturnSelectedRemoteWorkspace()
            }
          } else {
            Button("Clean Up Remote Copy…") {
              model.selectWorktree(repositoryID: repository.id, path: repository.path)
              model.requestCleanupSelectedRemoteWorkspace()
            }
          }
          Button("Move Project to Top") {
            model.moveRepositoryToTop(repository)
          }
          .disabled(model.repositories.first?.id == repository.id)
          Divider()
          Button("Open Project in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([
              URL(fileURLWithPath: repository.path)
            ])
          }
          if !externalWorktrees.isEmpty {
            Menu("Other Worktrees (\(externalWorktrees.count))") {
              ForEach(externalWorktrees) { worktree in
                Button {
                  model.selectWorktree(repositoryID: repository.id, path: worktree.path)
                } label: {
                  if model.selectedRepositoryID == repository.id
                    && model.selectedWorktreePath == worktree.path
                  {
                    Label(worktree.displayName, systemImage: "checkmark")
                  } else {
                    Text(worktree.displayName)
                  }
                }
              }
            }
          }
          Divider()
          Button("Remove Project…", role: .destructive) {
            model.requestRemoveProject(repository)
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .medium))
            .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Project Actions")
      }
      .padding(.leading, 8)
      .padding(.trailing, 3)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(mainSelected ? palette.selection : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      if !isCollapsed {
        if let pendingWorktree {
          pendingWorktreeRow(pendingWorktree)
        }

        ForEach(managedWorktrees) { worktree in
          worktreeRow(repository: repository, worktree: worktree)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func pendingWorktreeRow(_ pending: WorktreeCreation) -> some View {
    let selected = model.selectedPendingWorktreeID == pending.id
    return Button {
      model.selectPendingWorktree(pending.id)
    } label: {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.mini)
          .tint(palette.accent)
          .frame(width: 14)

        Text("Creating worktree…")
          .font(.feather(size: 14, weight: selected ? .semibold : .regular))
          .foregroundStyle(palette.secondaryText)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .frame(height: 35)
      .background(selected ? palette.selection : .clear)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .help("Fetching the latest base and preparing the checkout")
  }

  private func worktreeRow(
    repository: RepositoryRecord,
    worktree: GitWorktree
  ) -> some View {
    let selected =
      model.selectedRepositoryID == repository.id
      && model.selectedWorktreePath == worktree.path
    let isAvailable =
      model.managedWorktreeState(repositoryID: repository.id, path: worktree.path) == .available
    let agents = agentSessions(repositoryID: repository.id, worktreePath: worktree.path)
    let remoteWorkspace = model.remoteWorkspace(
      repositoryID: repository.id,
      worktreePath: worktree.path
    )
    return Button {
      model.selectWorktree(repositoryID: repository.id, path: worktree.path)
    } label: {
      HStack(spacing: 8) {
        Image(
          systemName: remoteWorkspace.map {
            $0.isRemoteAuthoritative ? "network" : "externaldrive.badge.checkmark"
          } ?? (isAvailable ? "shippingbox" : "arrow.triangle.branch")
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(selected ? palette.accent : palette.secondaryText)
        .frame(width: 14)

        Text(worktree.branchDisplayName ?? worktree.displayName)
          .font(.feather(size: 14, weight: selected ? .semibold : .regular))
          .foregroundStyle(isAvailable ? palette.secondaryText : palette.primaryText)
          .lineLimit(1)

        Spacer(minLength: 0)

        if !agents.isEmpty {
          AgentSessionBadges(sessions: agents)
        }

        if let remoteWorkspace {
          Text(remoteWorkspace.isRemoteAuthoritative ? remoteWorkspace.profileName : "Returned")
            .font(.feather(size: 10, weight: .medium))
            .foregroundStyle(palette.mutedText)
            .lineLimit(1)
        }

        if isAvailable {
          Text("Available")
            .font(.feather(size: 10, weight: .medium))
            .foregroundStyle(palette.mutedText)
        }
      }
      .padding(.horizontal, 9)
      .frame(height: 35)
      .background(selected ? palette.selection : .clear)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Open in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
      }
      if let remoteWorkspace, remoteWorkspace.isRemoteAuthoritative {
        Button("Reconnect Remote Workspace") {
          model.selectWorktree(repositoryID: repository.id, path: worktree.path)
          model.reconnectSelectedRemoteWorkspace()
        }
        Button("Return Workspace to This Mac…") {
          model.selectWorktree(repositoryID: repository.id, path: worktree.path)
          model.requestReturnSelectedRemoteWorkspace()
        }
      } else if remoteWorkspace?.returned != nil {
        Button("Clean Up Remote Copy…") {
          model.selectWorktree(repositoryID: repository.id, path: worktree.path)
          model.requestCleanupSelectedRemoteWorkspace()
        }
      } else if isAvailable {
        Button("Reuse Worktree") {
          model.reuseWorktree(repository: repository, worktree: worktree)
        }
      } else {
        Button("New Terminal") {
          model.selectWorktree(repositoryID: repository.id, path: worktree.path)
          NotificationCenter.default.post(name: .featherNewTerminalRequested, object: nil)
        }
        Button("Run Remotely…") {
          model.selectWorktree(repositoryID: repository.id, path: worktree.path)
          model.requestRunSelectedWorkspaceRemotely()
        }
        Button("Return for Reuse…") {
          model.requestReturnWorktree(repository: repository, worktree: worktree)
        }
      }
      if remoteWorkspace == nil {
        Divider()
        Button("Remove Worktree", role: .destructive) {
          model.requestRemoveWorktree(repository: repository, worktree: worktree)
        }
      }
    }
    .help(worktree.path)
  }

  private func agentSessions(
    repositoryID: UUID,
    worktreePath: String
  ) -> [AgentSessionPresentation] {
    model.terminals(repositoryID: repositoryID, worktreePath: worktreePath)
      .compactMap { terminal in
        guard let kind = AgentKind(terminal: terminal) else { return nil }
        return AgentSessionPresentation(
          id: terminal.id,
          kind: kind,
          state: model.runtimeState(for: terminal)
        )
      }
  }
}
