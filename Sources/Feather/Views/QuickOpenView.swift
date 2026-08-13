import FeatherCore
import SwiftUI

@MainActor
private final class QuickOpenModel: ObservableObject {
  @Published var query = "" {
    didSet { scheduleMatch() }
  }
  @Published private(set) var results: [String] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?

  let rootPath: String
  private let service = QuickOpenService()
  private var paths: [String] = []
  private var loadTask: Task<Void, Never>?
  private var matchTask: Task<Void, Never>?
  private var matchWorker: Task<[String], Never>?

  init(rootPath: String) {
    self.rootPath = rootPath
  }

  func start() {
    guard paths.isEmpty, loadTask == nil else { return }
    isLoading = true
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let loaded = try await service.files(worktreePath: rootPath)
        guard !Task.isCancelled else { return }
        paths = loaded
        scheduleMatch()
      } catch is CancellationError {
        return
      } catch {
        self.error = error.localizedDescription
      }
      isLoading = false
      loadTask = nil
    }
  }

  func cancel() {
    loadTask?.cancel()
    matchTask?.cancel()
    matchWorker?.cancel()
    loadTask = nil
    matchTask = nil
    matchWorker = nil
    paths.removeAll(keepingCapacity: false)
    results.removeAll(keepingCapacity: false)
    isLoading = false
    error = nil
  }

  private func scheduleMatch() {
    matchTask?.cancel()
    matchWorker?.cancel()
    let candidates = paths
    let needle = query
    let worker = Task.detached(priority: .userInitiated) {
      QuickOpenMatcher.matches(candidates, query: needle)
    }
    matchWorker = worker
    matchTask = Task { [weak self] in
      guard let self else { return }
      let matches = await worker.value
      guard !Task.isCancelled, query == needle else { return }
      results = matches
      matchWorker = nil
      matchTask = nil
    }
  }
}

struct QuickOpenView: View {
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model: QuickOpenModel
  @State private var selectedIndex = 0
  @FocusState private var queryIsFocused: Bool
  let onOpen: (String) -> Void
  let onDismiss: () -> Void

  init(rootPath: String, onOpen: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
    _model = StateObject(wrappedValue: QuickOpenModel(rootPath: rootPath))
    self.onOpen = onOpen
    self.onDismiss = onDismiss
  }

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.36)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)

      VStack(spacing: 0) {
        HStack(spacing: 9) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.secondaryText)
          TextField("Quick Open", text: $model.query)
            .textFieldStyle(.plain)
            .font(.feather(size: 15))
            .foregroundStyle(palette.primaryText)
            .focused($queryIsFocused)
            .onSubmit(openSelection)
            .onKeyPress(.downArrow) {
              moveSelection(1)
              return .handled
            }
            .onKeyPress(.upArrow) {
              moveSelection(-1)
              return .handled
            }
            .onKeyPress(.escape) {
              onDismiss()
              return .handled
            }
          if model.isLoading {
            ProgressView().controlSize(.mini)
          } else {
            Text("⌘P")
              .font(.system(size: 9, weight: .medium, design: .rounded))
              .foregroundStyle(palette.mutedText)
              .padding(.horizontal, 6)
              .frame(height: 20)
              .background(palette.selection)
              .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)

        Rectangle().fill(palette.border).frame(height: 1)

        results
          .frame(height: 330)
      }
      .frame(width: 590)
      .background(palette.titlebar)
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(palette.border, lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
      .padding(.top, 72)
    }
    .onAppear {
      queryIsFocused = true
      model.start()
    }
    .onDisappear { model.cancel() }
    .onChange(of: model.results) { _, results in
      selectedIndex = min(selectedIndex, max(results.count - 1, 0))
    }
    .onExitCommand(perform: onDismiss)
  }

  @ViewBuilder
  private var results: some View {
    if let error = model.error {
      VStack(spacing: 9) {
        Image(systemName: "exclamationmark.triangle")
        Text(error).multilineTextAlignment(.center)
      }
      .font(.feather(size: 11))
      .foregroundStyle(palette.secondaryText)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.isLoading && model.results.isEmpty {
      ProgressView().controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.results.isEmpty {
      Text(model.query.isEmpty ? "No files in this worktree" : "No matching files")
        .font(.feather(size: 11))
        .foregroundStyle(palette.mutedText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.results.enumerated()), id: \.element) { index, path in
              Button {
                selectedIndex = index
                openSelection()
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: fileSymbol(path))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.mutedText)
                    .frame(width: 14)
                  Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.feather(size: 12, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                  let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                  if parent != "." {
                    Text(parent)
                      .font(.feather(size: 10))
                      .foregroundStyle(palette.mutedText)
                      .lineLimit(1)
                  }
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 29)
                .background(
                  index == selectedIndex ? palette.selection : .clear,
                  in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .id(index)
            }
          }
          .padding(5)
        }
        .onChange(of: selectedIndex) { _, value in
          withAnimation(.easeOut(duration: 0.08)) {
            proxy.scrollTo(value, anchor: .center)
          }
        }
      }
    }
  }

  private func moveSelection(_ offset: Int) {
    guard !model.results.isEmpty else { return }
    selectedIndex = min(max(selectedIndex + offset, 0), model.results.count - 1)
  }

  private func openSelection() {
    guard model.results.indices.contains(selectedIndex) else { return }
    let path = URL(fileURLWithPath: model.rootPath)
      .appendingPathComponent(model.results[selectedIndex]).path
    onOpen(path)
  }

  private func fileSymbol(_ path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "swift": "swift"
    case "md", "markdown": "doc.richtext"
    case "json", "toml", "yaml", "yml", "plist": "curlybraces"
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": "photo"
    case "sh", "zsh", "bash", "fish": "terminal"
    default: "doc"
    }
  }
}
