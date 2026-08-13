import AppKit
import FeatherCore
import SwiftUI

@MainActor
private final class SourceControlModel: ObservableObject {
  enum Scope: String, CaseIterable, Identifiable {
    case workingTree = "Working Tree"
    case branchReview = "Branch Review"

    var id: String { rawValue }
  }

  private enum Action {
    case stage(String)
    case unstage(String)
    case stageAll
    case unstageAll
    case discard(String)
    case trash(String)
    case commit(String)
    case push
  }

  @Published private(set) var snapshot: GitStatusSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var isActing = false
  @Published private(set) var message: String?
  @Published private(set) var stagedLineStats: [String: GitLineStat] = [:]
  @Published private(set) var worktreeLineStats: [String: GitLineStat] = [:]
  @Published private(set) var scope = Scope.workingTree
  @Published private(set) var review: RepositoryReviewSnapshot?
  @Published private(set) var reviewBases: [String] = []
  @Published private(set) var selectedReviewBase = ""
  @Published var commitMessage = ""

  let rootPath: String
  private let service = GitWorkspaceService()
  private var statusTask: Task<Void, Never>?
  private var actionTask: Task<Void, Never>?

  init(rootPath: String) {
    self.rootPath = rootPath
  }

  func start() {
    guard statusTask == nil else { return }
    refresh()
  }

  func refresh() {
    statusTask?.cancel()
    isLoading = true
    message = nil
    statusTask = Task { [weak self] in
      guard let self else { return }
      do {
        switch scope {
        case .workingTree: try await reloadState()
        case .branchReview: try await reloadReview()
        }
      } catch is CancellationError {
        return
      } catch {
        message = error.localizedDescription
      }
      isLoading = false
      statusTask = nil
    }
  }

  func selectScope(_ next: Scope) {
    guard scope != next else { return }
    scope = next
    message = nil
    refresh()
  }

  func selectReviewBase(_ base: String) {
    guard selectedReviewBase != base else { return }
    selectedReviewBase = base
    review = nil
    refresh()
  }

  func stage(_ file: GitStatusFile) { perform(.stage(file.path)) }
  func unstage(_ file: GitStatusFile) { perform(.unstage(file.path)) }
  func stageAll() { perform(.stageAll) }
  func unstageAll() { perform(.unstageAll) }
  func discard(_ file: GitStatusFile) { perform(.discard(file.path)) }
  func trash(_ file: GitStatusFile) { perform(.trash(file.path)) }

  func commit() {
    let value = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    perform(.commit(value))
  }

  func push() { perform(.push) }

  var totalAdditions: Int {
    (Array(stagedLineStats.values) + Array(worktreeLineStats.values))
      .compactMap(\.additions).reduce(0, +)
  }

  var totalDeletions: Int {
    (Array(stagedLineStats.values) + Array(worktreeLineStats.values))
      .compactMap(\.deletions).reduce(0, +)
  }

  var hasLineStats: Bool { !stagedLineStats.isEmpty || !worktreeLineStats.isEmpty }

  var reviewHasLineStats: Bool {
    review?.files.contains { $0.additions != nil || $0.deletions != nil } == true
  }

  func lineStat(for path: String, staged: Bool) -> GitLineStat? {
    (staged ? stagedLineStats : worktreeLineStats)[path]
  }

  func cancel() {
    statusTask?.cancel()
    actionTask?.cancel()
    statusTask = nil
    actionTask = nil
    isLoading = false
    isActing = false
    snapshot = nil
    review = nil
    reviewBases.removeAll(keepingCapacity: false)
    selectedReviewBase = ""
    stagedLineStats.removeAll(keepingCapacity: false)
    worktreeLineStats.removeAll(keepingCapacity: false)
  }

  private func perform(_ action: Action) {
    statusTask?.cancel()
    actionTask?.cancel()
    isActing = true
    message = nil
    actionTask = Task { [weak self] in
      guard let self else { return }
      do {
        switch action {
        case .stage(let path):
          try await service.stage(worktreePath: rootPath, path: path)
        case .unstage(let path):
          try await service.unstage(worktreePath: rootPath, path: path)
        case .stageAll:
          try await service.stageAll(worktreePath: rootPath)
        case .unstageAll:
          try await service.unstageAll(worktreePath: rootPath)
        case .discard(let path):
          try await service.discardTrackedChanges(worktreePath: rootPath, path: path)
        case .trash(let path):
          try await trashUntracked(path)
        case .commit(let commitMessage):
          let output = try await service.commit(worktreePath: rootPath, message: commitMessage)
          self.commitMessage = ""
          message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        case .push:
          let output = try await service.push(worktreePath: rootPath)
          message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await reloadState()
      } catch is CancellationError {
        return
      } catch {
        message = error.localizedDescription
      }
      isActing = false
      actionTask = nil
    }
  }

  private func reloadState() async throws {
    let next = try await service.status(worktreePath: rootPath)
    guard !Task.isCancelled else { throw CancellationError() }
    snapshot = next

    do {
      let needsStagedStats = next.files.contains(where: \.isStaged)
      let needsWorktreeStats = next.files.contains {
        $0.hasWorktreeChanges && !$0.isUntracked
      }
      async let staged: [GitLineStat] =
        needsStagedStats ? service.diffStats(worktreePath: rootPath, staged: true) : []
      async let worktree: [GitLineStat] =
        needsWorktreeStats ? service.diffStats(worktreePath: rootPath, staged: false) : []
      let (nextStaged, nextWorktree) = try await (staged, worktree)
      guard !Task.isCancelled else { throw CancellationError() }
      stagedLineStats = keyed(nextStaged)
      worktreeLineStats = keyed(nextWorktree)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // A valid status list is still useful if Git cannot produce numstat output.
      stagedLineStats = [:]
      worktreeLineStats = [:]
    }
  }

  private func reloadReview() async throws {
    if reviewBases.isEmpty {
      var bases = try await service.reviewBases(worktreePath: rootPath)
      let initialBase = try await service.defaultReviewBase(
        worktreePath: rootPath,
        knownBases: bases
      )
      guard !Task.isCancelled else { throw CancellationError() }
      if !bases.contains(initialBase) { bases.insert(initialBase, at: 0) }
      reviewBases = bases
      if selectedReviewBase.isEmpty { selectedReviewBase = initialBase }
    }
    let base = selectedReviewBase.isEmpty ? "HEAD" : selectedReviewBase
    review = try await service.repositoryReview(
      worktreePath: rootPath,
      baseReference: base
    )
  }

  private func keyed(_ stats: [GitLineStat]) -> [String: GitLineStat] {
    Dictionary(stats.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
  }

  private func trashUntracked(_ relativePath: String) async throws {
    let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
    let file = root.appendingPathComponent(relativePath).standardizedFileURL
    guard file.path.hasPrefix(root.path + "/") else { throw WorkspaceFileError.outsideRoot }
    try await Task.detached(priority: .utility) {
      try FileManager.default.trashItem(at: file, resultingItemURL: nil)
    }.value
  }
}

struct SourceControlInspectorView: View {
  private struct PendingDiscard: Identifiable {
    let id = UUID()
    let file: GitStatusFile
  }

  private enum SectionKind: String {
    case conflicts = "Conflicts"
    case staged = "Staged Changes"
    case changes = "Changes"
    case untracked = "Untracked"
  }

  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model: SourceControlModel
  @State private var pendingDiscard: PendingDiscard?
  @State private var collapsedSections: Set<SectionKind> = []
  let selectedDocumentPath: String?
  let onOpenDiff: (GitStatusFile, Bool) -> Void
  let onOpenReviewDiff: (RepositoryReviewFile, String) -> Void

  init(
    rootPath: String,
    selectedDocumentPath: String?,
    onOpenDiff: @escaping (GitStatusFile, Bool) -> Void,
    onOpenReviewDiff: @escaping (RepositoryReviewFile, String) -> Void
  ) {
    _model = StateObject(wrappedValue: SourceControlModel(rootPath: rootPath))
    self.selectedDocumentPath = selectedDocumentPath
    self.onOpenDiff = onOpenDiff
    self.onOpenReviewDiff = onOpenReviewDiff
  }

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      sourceHeader
      reviewBaseBar
      changeSummary
      changeList
      if model.scope == .workingTree { commitBar }
    }
    .task {
      // Let the selected tab paint before starting repository I/O.
      await Task.yield()
      guard !Task.isCancelled else { return }
      model.start()
    }
    .onDisappear { model.cancel() }
    .alert(item: $pendingDiscard) { pending in
      let untracked = pending.file.isUntracked
      return Alert(
        title: Text(untracked ? "Move this file to Trash?" : "Discard these changes?"),
        message: Text(
          untracked
            ? pending.file.path
            : "Git will restore \(pending.file.path). This cannot be undone in Feather."
        ),
        primaryButton: .destructive(Text(untracked ? "Move to Trash" : "Discard")) {
          if untracked {
            model.trash(pending.file)
          } else {
            model.discard(pending.file)
          }
        },
        secondaryButton: .cancel()
      )
    }
  }

  @ViewBuilder
  private var changeSummary: some View {
    if model.scope == .branchReview, let review = model.review, !review.files.isEmpty {
      summaryRow(
        count: review.files.count,
        additions: review.additions,
        deletions: review.deletions,
        showsStats: model.reviewHasLineStats
      )
    } else if model.scope == .workingTree, let snapshot = model.snapshot,
      !snapshot.files.isEmpty
    {
      summaryRow(
        count: snapshot.files.count,
        additions: model.totalAdditions,
        deletions: model.totalDeletions,
        showsStats: model.hasLineStats
      )
    }
  }

  private func summaryRow(
    count: Int,
    additions: Int,
    deletions: Int,
    showsStats: Bool
  ) -> some View {
    HStack(spacing: 8) {
      Text("\(count) changed \(count == 1 ? "file" : "files")")
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
      Spacer(minLength: 0)
      if showsStats {
        Text("+\(additions)")
          .foregroundStyle(Color(hex: 0xADDB67))
        Text("−\(deletions)")
          .foregroundStyle(Color(hex: 0xEF5350))
      }
    }
    .font(.system(size: 10, weight: .medium, design: .monospaced))
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background(palette.terminal.opacity(0.35))
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.border.opacity(0.5)).frame(height: 1)
    }
  }

  private var sourceHeader: some View {
    HStack(spacing: 7) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.secondaryText)
      Text(model.snapshot?.branch ?? "Detached HEAD")
        .font(.feather(size: 12, weight: .semibold))
        .foregroundStyle(palette.primaryText)
        .lineLimit(1)
      if let snapshot = model.snapshot, snapshot.ahead > 0 || snapshot.behind > 0 {
        Text("↑\(snapshot.ahead) ↓\(snapshot.behind)")
          .font(.feather(size: 10, weight: .medium))
          .foregroundStyle(palette.mutedText)
      }
      Spacer(minLength: 0)
      Menu {
        ForEach(SourceControlModel.Scope.allCases) { scope in
          Button {
            model.selectScope(scope)
          } label: {
            if model.scope == scope {
              Label(scope.rawValue, systemImage: "checkmark")
            } else {
              Text(scope.rawValue)
            }
          }
        }
      } label: {
        HStack(spacing: 3) {
          Text(model.scope == .workingTree ? "Working" : "Review")
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .semibold))
        }
        .font(.feather(size: 9, weight: .medium))
        .foregroundStyle(palette.secondaryText)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Choose Working Tree or repository-wide Branch Review")
      if model.isLoading || model.isActing {
        ProgressView().controlSize(.mini)
      }
      Button(action: model.refresh) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .disabled(model.isLoading || model.isActing)
      .help("Refresh Changes")
    }
    .padding(.horizontal, 10)
    .frame(height: 35)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.border.opacity(0.65)).frame(height: 1)
    }
  }

  @ViewBuilder
  private var reviewBaseBar: some View {
    if model.scope == .branchReview {
      HStack(spacing: 7) {
        Text("COMPARE WITH")
          .font(.feather(size: 9, weight: .semibold))
          .foregroundStyle(palette.mutedText)
        Spacer(minLength: 0)
        Menu {
          ForEach(model.reviewBases, id: \.self) { base in
            Button {
              model.selectReviewBase(base)
            } label: {
              if model.selectedReviewBase == base {
                Label(base, systemImage: "checkmark")
              } else {
                Text(base)
              }
            }
          }
        } label: {
          HStack(spacing: 4) {
            Text(model.selectedReviewBase.isEmpty ? "Loading…" : model.selectedReviewBase)
              .lineLimit(1)
            Image(systemName: "chevron.down")
              .font(.system(size: 7, weight: .semibold))
          }
          .font(.feather(size: 10, weight: .medium))
          .foregroundStyle(palette.primaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(model.reviewBases.isEmpty)
      }
      .padding(.horizontal, 10)
      .frame(height: 31)
      .background(palette.terminal.opacity(0.22))
      .overlay(alignment: .bottom) {
        Rectangle().fill(palette.border.opacity(0.5)).frame(height: 1)
      }
    }
  }

  @ViewBuilder
  private var changeList: some View {
    if model.scope == .branchReview {
      reviewList
    } else if let snapshot = model.snapshot {
      if snapshot.files.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "checkmark.circle")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(palette.accent)
          Text("Working tree clean")
            .font(.feather(size: 12, weight: .medium))
            .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            changeSection(.conflicts, files: snapshot.files.filter(\.isConflicted))
            changeSection(
              .staged,
              files: snapshot.files.filter { $0.isStaged && !$0.isConflicted }
            )
            changeSection(
              .changes,
              files: snapshot.files.filter {
                $0.hasWorktreeChanges && !$0.isUntracked && !$0.isConflicted
              }
            )
            changeSection(.untracked, files: snapshot.files.filter(\.isUntracked))
            if snapshot.isTruncated {
              Text("More than 5,000 changes — use Git in Terminal for the full list.")
                .font(.feather(size: 10))
                .foregroundStyle(palette.mutedText)
                .padding(10)
            }
          }
        }
      }
    } else if model.isLoading {
      ProgressView().controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Text(model.message ?? "Source control is unavailable.")
        .font(.feather(size: 11))
        .foregroundStyle(palette.secondaryText)
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var reviewList: some View {
    if let review = model.review {
      if review.files.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "checkmark.circle")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(palette.accent)
          Text("No branch changes")
            .font(.feather(size: 12, weight: .medium))
            .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
              Text("BRANCH CHANGES")
                .font(.feather(size: 10, weight: .semibold))
              Spacer(minLength: 0)
              Text("\(review.files.count)")
                .font(.feather(size: 10))
            }
            .foregroundStyle(palette.mutedText)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ForEach(review.files) { file in
              reviewRow(file, baseReference: review.baseReference)
            }
            if review.isTruncated {
              Text("More than 5,000 changes — narrow the review with Git in Terminal.")
                .font(.feather(size: 10))
                .foregroundStyle(palette.mutedText)
                .padding(10)
            }
          }
        }
      }
    } else if model.isLoading {
      ProgressView().controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Text(model.message ?? "Repository review is unavailable.")
        .font(.feather(size: 11))
        .foregroundStyle(palette.secondaryText)
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func reviewRow(
    _ file: RepositoryReviewFile,
    baseReference: String
  ) -> some View {
    Button {
      onOpenReviewDiff(file, baseReference)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "doc")
          .font(.system(size: 10))
          .foregroundStyle(palette.mutedText)
          .frame(width: 13)
        VStack(alignment: .leading, spacing: 1) {
          Text(URL(fileURLWithPath: file.path).lastPathComponent)
            .font(.feather(size: 12))
            .foregroundStyle(palette.primaryText)
            .lineLimit(1)
          let parent = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
          if parent != "." && parent != "/" {
            Text(parent)
              .font(.feather(size: 9))
              .foregroundStyle(palette.mutedText)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: 4) {
          if let additions = file.additions, additions > 0 {
            Text("+\(additions)").foregroundStyle(Color(hex: 0xADDB67))
          }
          if let deletions = file.deletions, deletions > 0 {
            Text("−\(deletions)").foregroundStyle(Color(hex: 0xEF5350))
          }
          if file.additions == nil, file.deletions == nil, !file.isUntracked {
            Text("BIN").foregroundStyle(palette.mutedText)
          }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        Text(file.isUntracked ? "U" : "M")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .foregroundStyle(file.isUntracked ? palette.accent : Color(hex: 0x82AAFF))
          .frame(width: 14)
      }
      .padding(.horizontal, 10)
      .frame(minHeight: 29)
      .background(
        absolutePath(for: file.path) == selectedDocumentPath ? palette.selection : .clear,
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("View Branch Diff") { onOpenReviewDiff(file, baseReference) }
    }
    .help(file.path)
  }

  @ViewBuilder
  private func changeSection(_ section: SectionKind, files: [GitStatusFile]) -> some View {
    if !files.isEmpty {
      let collapsed = collapsedSections.contains(section)
      let stats = files.compactMap {
        model.lineStat(for: $0.path, staged: section == .staged)
      }
      HStack(spacing: 6) {
        Button {
          if collapsed {
            collapsedSections.remove(section)
          } else {
            collapsedSections.insert(section)
          }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
              .font(.system(size: 8, weight: .semibold))
              .frame(width: 9)
            Text(section.rawValue.uppercased())
              .font(.feather(size: 10, weight: .semibold))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.mutedText)
        .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(section.rawValue)")
        Spacer(minLength: 0)
        if !stats.isEmpty {
          let additions = stats.compactMap(\.additions).reduce(0, +)
          let deletions = stats.compactMap(\.deletions).reduce(0, +)
          Text("+\(additions)")
            .foregroundStyle(Color(hex: 0xADDB67))
          Text("−\(deletions)")
            .foregroundStyle(Color(hex: 0xEF5350))
        }
        Text("\(files.count)")
          .font(.feather(size: 10))
          .foregroundStyle(palette.mutedText)
        if section != .conflicts {
          Button(section == .staged ? "Unstage" : "Stage All") {
            if section == .staged {
              model.unstageAll()
            } else {
              model.stageAll()
            }
          }
          .buttonStyle(.plain)
          .font(.feather(size: 10, weight: .medium))
          .foregroundStyle(palette.secondaryText)
          .disabled(model.isActing)
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 4)
      .font(.system(size: 9, weight: .medium, design: .monospaced))

      if !collapsed {
        ForEach(files) { file in
          changeRow(file, section: section)
        }
      }
    }
  }

  private func changeRow(_ file: GitStatusFile, section: SectionKind) -> some View {
    let staged = section == .staged
    let lineStat = model.lineStat(for: file.path, staged: staged)
    return HStack(spacing: 6) {
      Button {
        onOpenDiff(file, staged)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: file.isConflicted ? "exclamationmark.triangle" : "doc")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(file.isConflicted ? Color.orange : palette.mutedText)
            .frame(width: 13)
          VStack(alignment: .leading, spacing: 1) {
            Text(URL(fileURLWithPath: file.path).lastPathComponent)
              .font(.feather(size: 12))
              .foregroundStyle(palette.primaryText)
              .lineLimit(1)
            let parent = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
            if parent != "." && parent != "/" {
              Text(parent)
                .font(.feather(size: 9))
                .foregroundStyle(palette.mutedText)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("View diff for \(file.path)")

      if let lineStat {
        HStack(spacing: 4) {
          if let additions = lineStat.additions, additions > 0 {
            Text("+\(additions)").foregroundStyle(Color(hex: 0xADDB67))
          }
          if let deletions = lineStat.deletions, deletions > 0 {
            Text("−\(deletions)").foregroundStyle(Color(hex: 0xEF5350))
          }
          if lineStat.additions == nil, lineStat.deletions == nil {
            Text("BIN").foregroundStyle(palette.mutedText)
          }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
      }

      Text(statusLabel(file, section: section))
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(statusColor(file, section: section))
        .frame(width: 14)

      if !file.isConflicted {
        Button {
          staged ? model.unstage(file) : model.stage(file)
        } label: {
          Image(systemName: staged ? "minus" : "plus")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondaryText)
        .disabled(model.isActing)
        .help(staged ? "Unstage" : "Stage")
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 8)
    .frame(minHeight: 29)
    .background(
      absolutePath(for: file) == selectedDocumentPath ? palette.selection : .clear,
      in: RoundedRectangle(cornerRadius: 5, style: .continuous)
    )
    .contextMenu {
      Button("View Diff") { onOpenDiff(file, staged) }
      if !file.isConflicted {
        Button(staged ? "Unstage" : "Stage") {
          staged ? model.unstage(file) : model.stage(file)
        }
      }
      if !staged && !file.isConflicted {
        Divider()
        Button(file.isUntracked ? "Move to Trash…" : "Discard Changes…", role: .destructive) {
          pendingDiscard = PendingDiscard(file: file)
        }
      }
    }
    .help(file.path)
  }

  private var commitBar: some View {
    VStack(spacing: 7) {
      if let message = model.message, !message.isEmpty {
        Text(message)
          .font(.feather(size: 10))
          .foregroundStyle(palette.secondaryText)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      TextField("Commit message", text: $model.commitMessage)
        .textFieldStyle(.roundedBorder)
        .font(.feather(size: 12))
        .onSubmit(model.commit)
      HStack(spacing: 7) {
        Button("Commit", action: model.commit)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(
            model.isActing
              || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || model.snapshot?.files.contains(where: \.isStaged) != true
          )
        Button(action: model.push) {
          Label("Push", systemImage: "arrow.up")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isActing)
        Spacer(minLength: 0)
      }
    }
    .padding(9)
    .background(palette.titlebar)
    .overlay(alignment: .top) {
      Rectangle().fill(palette.border).frame(height: 1)
    }
  }

  private func statusLabel(_ file: GitStatusFile, section: SectionKind) -> String {
    if file.isConflicted { return "!" }
    if file.isUntracked { return "U" }
    return String(section == .staged ? file.indexStatus : file.worktreeStatus)
  }

  private func statusColor(_ file: GitStatusFile, section: SectionKind) -> Color {
    if file.isConflicted { return .orange }
    if file.isUntracked || statusLabel(file, section: section) == "A" { return palette.accent }
    if statusLabel(file, section: section) == "D" { return Color(hex: 0xEF5350) }
    return Color(hex: 0x82AAFF)
  }

  private func absolutePath(for file: GitStatusFile) -> String {
    absolutePath(for: file.path)
  }

  private func absolutePath(for path: String) -> String {
    URL(fileURLWithPath: model.rootPath).appendingPathComponent(path).path
  }
}
