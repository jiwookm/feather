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

  @ViewBuilder
  private func repositorySection(_ repository: RepositoryRecord) -> some View {
    let externalWorktrees = model.externalWorktrees(for: repository)
    let managedWorktrees = model.projectWorktrees(for: repository)
    let pendingWorktree = model.pendingCreation(for: repository)
    let isCollapsed = collapsedRepositories.contains(repository.id)
    let hasChildren = pendingWorktree != nil || !managedWorktrees.isEmpty
    let mainAgents = agentKinds(repositoryID: repository.id, worktreePath: repository.path)
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

        if !mainAgents.isEmpty {
          AgentSessionBadges(kinds: mainAgents)
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
    let agents = agentKinds(repositoryID: repository.id, worktreePath: worktree.path)
    return Button {
      model.selectWorktree(repositoryID: repository.id, path: worktree.path)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isAvailable ? "shippingbox" : "arrow.triangle.branch")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(selected ? palette.accent : palette.secondaryText)
          .frame(width: 14)

        Text(worktree.branchDisplayName ?? worktree.displayName)
          .font(.feather(size: 14, weight: selected ? .semibold : .regular))
          .foregroundStyle(isAvailable ? palette.secondaryText : palette.primaryText)
          .lineLimit(1)

        Spacer(minLength: 0)

        if !agents.isEmpty {
          AgentSessionBadges(kinds: agents)
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
      if isAvailable {
        Button("Reuse Worktree") {
          model.reuseWorktree(repository: repository, worktree: worktree)
        }
      } else {
        Button("New Terminal") {
          model.selectWorktree(repositoryID: repository.id, path: worktree.path)
          NotificationCenter.default.post(name: .featherNewTerminalRequested, object: nil)
        }
        Button("Return for Reuse…") {
          model.requestReturnWorktree(repository: repository, worktree: worktree)
        }
      }
      Divider()
      Button("Remove Worktree", role: .destructive) {
        model.requestRemoveWorktree(repository: repository, worktree: worktree)
      }
    }
    .help(worktree.path)
  }

  private func agentKinds(repositoryID: UUID, worktreePath: String) -> [AgentKind] {
    model.terminals(repositoryID: repositoryID, worktreePath: worktreePath)
      .compactMap(AgentKind.init(terminal:))
  }
}
