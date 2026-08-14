import AppKit
import FeatherCore
import SwiftUI

@MainActor
private final class GitHubInspectorModel: ObservableObject {
  @Published private(set) var snapshot: GitHubPullRequestSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var isMerging = false
  @Published private(set) var hasNoPullRequest = false
  @Published private(set) var message: String?

  let rootPath: String
  let identity: GitHubRepositoryIdentity?
  private let service = GitHubService()
  private var task: Task<Void, Never>?

  init(rootPath: String, remoteURL: String?) {
    self.rootPath = rootPath
    identity = GitHubRepositoryIdentity(remoteURL: remoteURL)
  }

  func start() {
    guard snapshot == nil, task == nil else { return }
    refresh()
  }

  func refresh() {
    guard !isMerging else { return }
    task?.cancel()
    guard identity != nil else {
      message = "Origin is not a GitHub repository."
      return
    }
    isLoading = true
    hasNoPullRequest = false
    message = nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let next = try await service.currentPullRequest(worktreePath: rootPath)
        guard !Task.isCancelled else { return }
        snapshot = next
      } catch is CancellationError {
        return
      } catch GitHubServiceError.noPullRequest {
        snapshot = nil
        hasNoPullRequest = true
      } catch {
        snapshot = nil
        message = error.localizedDescription
      }
      isLoading = false
      task = nil
    }
  }

  func createPullRequest() {
    task?.cancel()
    isLoading = true
    message = nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try await service.createPullRequest(worktreePath: rootPath)
      } catch is CancellationError {
        return
      } catch {
        message = error.localizedDescription
      }
      isLoading = false
      task = nil
    }
  }

  func mergePullRequest() {
    guard task == nil, let snapshot, snapshot.mergeBlockReason == nil else { return }
    isMerging = true
    message = nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try await service.mergePullRequest(snapshot.pullRequest, worktreePath: rootPath)
        guard !Task.isCancelled else { return }
        do {
          self.snapshot = try await service.currentPullRequest(worktreePath: rootPath)
        } catch GitHubServiceError.noPullRequest {
          self.snapshot = nil
          hasNoPullRequest = true
        }
      } catch is CancellationError {
        return
      } catch {
        message = error.localizedDescription
      }
      isMerging = false
      task = nil
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
    isLoading = false
    isMerging = false
  }
}

struct GitHubInspectorView: View {
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model: GitHubInspectorModel
  @State private var mergeConfirmationPresented = false

  init(rootPath: String, repository: RepositoryRecord?) {
    _model = StateObject(
      wrappedValue: GitHubInspectorModel(rootPath: rootPath, remoteURL: repository?.remoteURL)
    )
  }

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      githubHeader
      content
    }
    .task { model.start() }
    .onDisappear { model.cancel() }
    .confirmationDialog(
      "Merge this pull request?",
      isPresented: $mergeConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Squash and Merge") { model.mergePullRequest() }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let pullRequest = model.snapshot?.pullRequest {
        Text(
          "Feather will merge #\(pullRequest.number) only if its verified head commit is still "
            + "current."
        )
      }
    }
  }

  private var githubHeader: some View {
    HStack(spacing: 7) {
      Image(systemName: "shippingbox")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.secondaryText)
      Text(model.identity.map { "\($0.owner)/\($0.repository)" } ?? "GitHub")
        .font(.feather(size: 12, weight: .semibold))
        .foregroundStyle(palette.primaryText)
        .lineLimit(1)
      Spacer(minLength: 0)
      if model.isLoading || model.isMerging { ProgressView().controlSize(.mini) }
      if let identity = model.identity {
        Button {
          NSWorkspace.shared.open(identity.webURL)
        } label: {
          Image(systemName: "arrow.up.right.square")
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(HoverButtonStyle())
        .help("Open Repository on GitHub")
      }
      Button(action: model.refresh) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .disabled(model.isLoading || model.isMerging || model.identity == nil)
      .help("Refresh GitHub")
    }
    .padding(.horizontal, 10)
    .frame(height: 35)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.border.opacity(0.65)).frame(height: 1)
    }
  }

  @ViewBuilder
  private var content: some View {
    if let snapshot = model.snapshot {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          pullRequestCard(snapshot)
          if let message = model.message {
            Text(message)
              .font(.feather(size: 10))
              .foregroundStyle(Color(hex: 0xEF5350))
          }
          checksSection(snapshot.checks)
        }
        .padding(10)
      }
    } else if model.isLoading {
      ProgressView().controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.hasNoPullRequest {
      emptyState(
        symbol: "arrow.triangle.pull",
        title: "No pull request",
        message: "Create one for the current branch in GitHub."
      ) {
        Button("Create Pull Request", action: model.createPullRequest)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      }
    } else {
      emptyState(
        symbol: "exclamationmark.circle",
        title: "GitHub unavailable",
        message: model.message ?? "Refresh to load the current branch's pull request."
      ) {
        if model.identity != nil {
          Button("Try Again", action: model.refresh)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
    }
  }

  private func pullRequestCard(_ snapshot: GitHubPullRequestSnapshot) -> some View {
    let pullRequest = snapshot.pullRequest
    return VStack(spacing: 0) {
      Button {
        NSWorkspace.shared.open(pullRequest.url)
      } label: {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 6) {
            Image(systemName: pullRequest.isDraft ? "circle.dotted" : "arrow.triangle.pull")
              .foregroundStyle(pullRequestColor(pullRequest))
            Text("#\(pullRequest.number)")
              .foregroundStyle(palette.secondaryText)
            Text(pullRequest.isDraft ? "DRAFT" : pullRequest.state.uppercased())
              .font(.feather(size: 9, weight: .semibold))
              .foregroundStyle(pullRequestColor(pullRequest))
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(palette.mutedText)
          }
          Text(pullRequest.title)
            .font(.feather(size: 13, weight: .semibold))
            .foregroundStyle(palette.primaryText)
            .multilineTextAlignment(.leading)
          Text("\(pullRequest.headRefName) → \(pullRequest.baseRefName)")
            .font(.feather(size: 10))
            .foregroundStyle(palette.mutedText)
            .lineLimit(1)
          if let author = pullRequest.author?.login {
            HStack(spacing: 6) {
              Text(author)
              if let decision = pullRequest.reviewDecision, !decision.isEmpty {
                Text(decision.replacingOccurrences(of: "_", with: " ").capitalized)
                  .foregroundStyle(palette.mutedText)
              }
            }
            .font(.feather(size: 10))
            .foregroundStyle(palette.secondaryText)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)

      if pullRequest.state.uppercased() == "OPEN" {
        Rectangle()
          .fill(palette.border.opacity(0.7))
          .frame(height: 1)

        HStack(spacing: 6) {
          Spacer(minLength: 0)
          Button("Merge") {
            mergeConfirmationPresented = true
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(snapshot.mergeBlockReason != nil || model.isMerging)
          .help(snapshot.mergeBlockReason ?? "Squash and merge this pull request")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
      }
    }
    .background(palette.selection)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  @ViewBuilder
  private func checksSection(_ checks: [GitHubCheck]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("CHECKS")
          .font(.feather(size: 10, weight: .semibold))
          .foregroundStyle(palette.mutedText)
        Spacer(minLength: 0)
        Text("\(checks.count)")
          .font(.feather(size: 10))
          .foregroundStyle(palette.mutedText)
      }

      if checks.isEmpty {
        Text("No checks reported")
          .font(.feather(size: 11))
          .foregroundStyle(palette.secondaryText)
          .padding(.vertical, 5)
      } else {
        ForEach(checks) { check in
          let subtitle = checkSubtitle(check)
          Button {
            if let link = check.link, let url = URL(string: link) {
              NSWorkspace.shared.open(url)
            }
          } label: {
            HStack(alignment: .center, spacing: 7) {
              Image(systemName: checkSymbol(check))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(checkColor(check))
                .frame(width: 14)
              if let subtitle {
                VStack(alignment: .leading, spacing: 1) {
                  Text(check.name)
                    .font(.feather(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                  Text(subtitle)
                    .font(.feather(size: 9))
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(1)
                }
              } else {
                Text(check.name)
                  .font(.feather(size: 11, weight: .medium))
                  .foregroundStyle(palette.primaryText)
                  .lineLimit(1)
                  .frame(height: 28, alignment: .center)
              }
              Spacer(minLength: 0)
              Text(check.state.lowercased())
                .font(.feather(size: 9))
                .foregroundStyle(palette.mutedText)
            }
            .frame(minHeight: 28)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(check.link == nil)
        }
      }
    }
  }

  private func emptyState<Actions: View>(
    symbol: String,
    title: String,
    message: String,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
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
      actions()
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func pullRequestColor(_ pullRequest: GitHubPullRequest) -> Color {
    if pullRequest.isDraft { return palette.mutedText }
    return pullRequest.state.uppercased() == "OPEN" ? palette.accent : Color(hex: 0xC792EA)
  }

  private func checkSymbol(_ check: GitHubCheck) -> String {
    switch check.bucket.lowercased() {
    case "pass": "checkmark.circle.fill"
    case "fail", "cancel": "xmark.circle.fill"
    case "pending": "clock"
    case "skipping": "minus.circle"
    default: "circle"
    }
  }

  private func checkColor(_ check: GitHubCheck) -> Color {
    switch check.bucket.lowercased() {
    case "pass": palette.accent
    case "fail", "cancel": Color(hex: 0xEF5350)
    case "pending": Color(hex: 0xFFCB6B)
    default: palette.mutedText
    }
  }

  private func checkSubtitle(_ check: GitHubCheck) -> String? {
    guard let workflow = check.workflow, workflow != check.name else { return nil }
    return workflow
  }
}
