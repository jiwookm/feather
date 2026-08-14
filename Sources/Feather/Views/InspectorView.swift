import AppKit
import FeatherCore
import SwiftUI

private enum InspectorTab: String, CaseIterable, Identifiable {
  case files
  case changes
  case github
  case usage

  var id: String { rawValue }

  var title: String {
    switch self {
    case .files: "Files"
    case .changes: "Changes"
    case .github: "GitHub"
    case .usage: "Usage"
    }
  }

  var systemImage: String {
    switch self {
    case .files: "doc.on.doc"
    case .changes: "arrow.triangle.branch"
    case .github: "point.3.connected.trianglepath.dotted"
    case .usage: "gauge.with.needle"
    }
  }
}

struct InspectorView: View {
  @Environment(\.colorScheme) private var colorScheme
  let repository: RepositoryRecord?
  let worktree: GitWorktree?
  let remoteWorkspace: RemoteWorkspaceRecord?
  let isFullScreen: Bool
  let selectedDocumentPath: String?
  let onOpenFile: (String) -> Void
  let onOpenDiff: (GitStatusFile, Bool) -> Void
  let onOpenReviewDiff: (RepositoryReviewFile, String) -> Void
  @State private var selectedTab = InspectorTab.files
  @State private var hoveredTab: InspectorTab?

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        ForEach(InspectorTab.allCases) { tab in
          Button {
            selectedTab = tab
          } label: {
            HStack(spacing: 5) {
              Image(systemName: tab.systemImage)
                .font(.system(size: 11, weight: .medium))
              Text(tab.title)
                .font(.feather(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .foregroundStyle(
              selectedTab == tab ? palette.primaryText : palette.secondaryText
            )
            .background(
              selectedTab == tab
                ? palette.selection : (hoveredTab == tab ? palette.hover : .clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
          }
          .buttonStyle(.plain)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .onHover { hovering in
            hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
          }
          .help(tab.title)
          .accessibilityLabel(tab.title)
          .accessibilityHint("Show the \(tab.title.lowercased()) inspector")
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(height: FeatherMetrics.titlebarHeight(isFullScreen))
      .background(palette.titlebar)
      .overlay(alignment: .bottom) {
        Rectangle().fill(palette.border).frame(height: 1)
      }

      Group {
        if selectedTab == .usage {
          ResourceInspectorView()
        } else if let worktree {
          switch selectedTab {
          case .files:
            if let remoteWorkspace {
              remoteCheckpointPlaceholder(remoteWorkspace)
            } else {
              FileInspectorView(
                rootPath: worktree.path,
                selectedDocumentPath: selectedDocumentPath,
                onOpenFile: onOpenFile
              )
            }
          case .changes:
            if let remoteWorkspace {
              remoteCheckpointPlaceholder(remoteWorkspace)
            } else {
              SourceControlInspectorView(
                rootPath: worktree.path,
                selectedDocumentPath: selectedDocumentPath,
                onOpenDiff: onOpenDiff,
                onOpenReviewDiff: onOpenReviewDiff
              )
            }
          case .github:
            if let remoteWorkspace {
              remoteCheckpointPlaceholder(remoteWorkspace)
            } else {
              GitHubInspectorView(
                rootPath: worktree.path,
                repository: repository
              )
            }
          case .usage:
            EmptyView()
          }
        } else {
          inspectorPlaceholder(
            symbol: "sidebar.right",
            title: "No worktree selected",
            message: "Select a project or worktree to inspect it."
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(palette.titlebar)
  }

  private func inspectorPlaceholder(symbol: String, title: String, message: String) -> some View {
    VStack(spacing: 9) {
      Image(systemName: symbol)
        .font(.system(size: 22, weight: .light))
        .foregroundStyle(palette.mutedText)
      Text(title)
        .font(.feather(size: 13, weight: .semibold))
        .foregroundStyle(palette.primaryText)
      Text(message)
        .font(.feather(size: 11))
        .foregroundStyle(palette.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 230)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func remoteCheckpointPlaceholder(_ workspace: RemoteWorkspaceRecord) -> some View {
    inspectorPlaceholder(
      symbol: "network",
      title: "Files are remote",
      message:
        "\(workspace.profileName) owns the current checkout. Feather will not present or modify the local checkpoint as though it were current."
    )
  }
}

@MainActor
private final class FileInspectorModel: ObservableObject {
  struct Row: Identifiable {
    let entry: WorkspaceFileEntry
    let depth: Int
    var id: String { entry.id }
  }

  enum LoadState {
    case loading
    case loaded(WorkspaceDirectoryListing)
    case failed(String)
  }

  @Published private(set) var states: [String: LoadState] = [:]
  @Published private(set) var expanded: Set<String> = []

  let rootPath: String
  private let service = WorkspaceFileService()
  private var tasks: [String: Task<Void, Never>] = [:]

  init(rootPath: String) {
    self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
  }

  var rows: [Row] {
    guard case .loaded(let root)? = states[rootPath] else { return [] }
    var result: [Row] = []
    append(root.entries, depth: 0, to: &result)
    return result
  }

  var rootState: LoadState? { states[rootPath] }

  func start() {
    guard states[rootPath] == nil else { return }
    load(rootPath)
  }

  func refresh() {
    cancel()
    states.removeAll(keepingCapacity: true)
    expanded.removeAll(keepingCapacity: true)
    load(rootPath)
  }

  func toggle(_ entry: WorkspaceFileEntry) {
    guard entry.isDirectory else { return }
    if expanded.remove(entry.path) != nil { return }
    expanded.insert(entry.path)
    if states[entry.path] == nil { load(entry.path) }
  }

  func cancel() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll(keepingCapacity: true)
  }

  private func load(_ path: String) {
    states[path] = .loading
    tasks[path]?.cancel()
    tasks[path] = Task { [weak self] in
      guard let self else { return }
      do {
        let listing = try await service.listDirectory(rootPath: rootPath, directoryPath: path)
        guard !Task.isCancelled else { return }
        states[path] = .loaded(listing)
      } catch is CancellationError {
        return
      } catch {
        states[path] = .failed(error.localizedDescription)
      }
      tasks[path] = nil
    }
  }

  private func append(_ entries: [WorkspaceFileEntry], depth: Int, to rows: inout [Row]) {
    guard depth < 64 else { return }
    for entry in entries {
      rows.append(Row(entry: entry, depth: depth))
      guard entry.isDirectory, expanded.contains(entry.path),
        case .loaded(let childListing)? = states[entry.path]
      else { continue }
      append(childListing.entries, depth: depth + 1, to: &rows)
    }
  }
}

private struct FileInspectorView: View {
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model: FileInspectorModel
  let selectedDocumentPath: String?
  let onOpenFile: (String) -> Void

  init(
    rootPath: String,
    selectedDocumentPath: String?,
    onOpenFile: @escaping (String) -> Void
  ) {
    _model = StateObject(wrappedValue: FileInspectorModel(rootPath: rootPath))
    self.selectedDocumentPath = selectedDocumentPath
    self.onOpenFile = onOpenFile
  }

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(URL(fileURLWithPath: model.rootPath).lastPathComponent)
          .font(.feather(size: 12, weight: .semibold))
          .foregroundStyle(palette.primaryText)
          .lineLimit(1)
        Spacer(minLength: 0)
        Button(action: model.refresh) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(HoverButtonStyle())
        .help("Refresh Files")
      }
      .padding(.horizontal, 10)
      .frame(height: 35)
      .overlay(alignment: .bottom) {
        Rectangle().fill(palette.border.opacity(0.65)).frame(height: 1)
      }

      content
    }
    .task { model.start() }
    .onDisappear { model.cancel() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.rootState {
    case .none, .loading:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      VStack(spacing: 9) {
        Text(message)
          .font(.feather(size: 11))
          .foregroundStyle(palette.secondaryText)
          .multilineTextAlignment(.center)
        Button("Try Again", action: model.refresh)
          .controlSize(.small)
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let root):
      if root.entries.isEmpty {
        Text("Empty folder")
          .font(.feather(size: 11))
          .foregroundStyle(palette.mutedText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
              fileRow(row)
            }
            if root.isTruncated {
              truncatedRow(depth: 0)
            }
          }
          .padding(.vertical, 4)
        }
        .scrollIndicators(.automatic)
      }
    }
  }

  private func fileRow(_ row: FileInspectorModel.Row) -> some View {
    let entry = row.entry
    return Button {
      if entry.isDirectory {
        model.toggle(entry)
      } else {
        onOpenFile(entry.path)
      }
    } label: {
      HStack(spacing: 5) {
        if entry.isDirectory {
          Image(systemName: model.expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(palette.mutedText)
            .frame(width: 10)
        } else {
          Color.clear.frame(width: 10, height: 1)
        }
        Image(systemName: fileSymbol(for: entry))
          .font(.system(size: 11, weight: .regular))
          .foregroundStyle(entry.isDirectory ? palette.secondaryText : palette.mutedText)
          .frame(width: 14)
        Text(entry.name)
          .font(.feather(size: 12))
          .foregroundStyle(palette.primaryText)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, CGFloat(8 + row.depth * 14))
      .padding(.trailing, 8)
      .frame(height: 25)
      .background(
        entry.path == selectedDocumentPath ? palette.selection : .clear,
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(entry.name)
    .accessibilityHint(entry.isDirectory ? "Expand folder" : "Open in Feather")
    .contextMenu {
      if !entry.isDirectory {
        Button("Open in Feather") { onOpenFile(entry.path) }
      }
      Button("Open Externally") { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
      Button("Reveal in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
      }
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
      }
    }
    .help(entry.path)
  }

  private func truncatedRow(depth: Int) -> some View {
    Text("More than 2,000 items — narrow this folder in Terminal")
      .font(.feather(size: 10))
      .foregroundStyle(palette.mutedText)
      .padding(.leading, CGFloat(37 + depth * 14))
      .frame(height: 25)
  }

  private func fileSymbol(for entry: WorkspaceFileEntry) -> String {
    if entry.isDirectory { return "folder" }
    if entry.isSymbolicLink { return "link" }
    switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
    case "swift": return "swift"
    case "md", "markdown": return "doc.richtext"
    case "json", "toml", "yaml", "yml", "plist": return "curlybraces"
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo"
    case "sh", "zsh", "bash", "fish": return "terminal"
    default: return "doc"
    }
  }
}
