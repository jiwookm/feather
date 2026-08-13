import FeatherCore
import SwiftUI

@MainActor
private final class RepositorySearchModel: ObservableObject {
  @Published var query = "" {
    didSet { scheduleSearch() }
  }
  @Published private(set) var snapshot = RepositorySearchSnapshot(
    matches: [],
    isTruncated: false
  )
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?

  let rootPath: String
  private let service = RepositorySearchService()
  private var searchTask: Task<Void, Never>?

  init(rootPath: String) {
    self.rootPath = rootPath
  }

  func cancel() {
    searchTask?.cancel()
    searchTask = nil
    snapshot = RepositorySearchSnapshot(matches: [], isTruncated: false)
    isLoading = false
    error = nil
  }

  private func scheduleSearch() {
    searchTask?.cancel()
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    error = nil
    guard needle.count >= 2 else {
      snapshot = RepositorySearchSnapshot(matches: [], isTruncated: false)
      isLoading = false
      return
    }

    searchTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == needle
        else { return }
        isLoading = true
        let result = try await service.search(worktreePath: rootPath, query: needle)
        guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == needle
        else { return }
        snapshot = result
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
        snapshot = RepositorySearchSnapshot(matches: [], isTruncated: false)
      }
      guard !Task.isCancelled else { return }
      isLoading = false
      searchTask = nil
    }
  }
}

struct RepositorySearchView: View {
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model: RepositorySearchModel
  @State private var selectedIndex = 0
  @FocusState private var queryIsFocused: Bool
  let onOpen: (RepositorySearchMatch) -> Void
  let onDismiss: () -> Void

  init(
    rootPath: String,
    onOpen: @escaping (RepositorySearchMatch) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    _model = StateObject(wrappedValue: RepositorySearchModel(rootPath: rootPath))
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
          Image(systemName: "text.magnifyingglass")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.secondaryText)
          TextField("Search Repository", text: $model.query)
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
            Text("⌘⇧F")
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
          .frame(height: 360)
      }
      .frame(width: 680)
      .background(palette.titlebar)
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(palette.border, lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
      .padding(.top, 72)
    }
    .onAppear { queryIsFocused = true }
    .onDisappear { model.cancel() }
    .onChange(of: model.snapshot.matches) { _, matches in
      selectedIndex = min(selectedIndex, max(matches.count - 1, 0))
    }
    .onExitCommand(perform: onDismiss)
  }

  @ViewBuilder
  private var results: some View {
    if let error = model.error {
      stateMessage(symbol: "exclamationmark.triangle", message: error)
    } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
      stateMessage(symbol: "text.magnifyingglass", message: "Type at least two characters")
    } else if model.isLoading && model.snapshot.matches.isEmpty {
      ProgressView().controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.snapshot.matches.isEmpty {
      stateMessage(symbol: "text.magnifyingglass", message: "No matching text")
    } else {
      VStack(spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(model.snapshot.matches.enumerated()), id: \.element.id) {
                index, match in
                resultButton(match, index: index)
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

        if model.snapshot.isTruncated {
          Text("Showing the first 200 matching lines")
            .font(.feather(size: 10))
            .foregroundStyle(palette.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
        }
      }
    }
  }

  private func resultButton(_ match: RepositorySearchMatch, index: Int) -> some View {
    Button {
      selectedIndex = index
      openSelection()
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(match.path)
            .font(.feather(size: 11, weight: .medium))
            .foregroundStyle(palette.primaryText)
            .lineLimit(1)
          Text("\(match.line):\(match.column)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.mutedText)
        }
        Text(match.preview)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(palette.secondaryText)
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
      .background(
        index == selectedIndex ? palette.selection : .clear,
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func stateMessage(symbol: String, message: String) -> some View {
    VStack(spacing: 9) {
      Image(systemName: symbol)
      Text(message).multilineTextAlignment(.center)
    }
    .font(.feather(size: 11))
    .foregroundStyle(palette.secondaryText)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func moveSelection(_ offset: Int) {
    guard !model.snapshot.matches.isEmpty else { return }
    selectedIndex = min(max(selectedIndex + offset, 0), model.snapshot.matches.count - 1)
  }

  private func openSelection() {
    guard model.snapshot.matches.indices.contains(selectedIndex) else { return }
    onOpen(model.snapshot.matches[selectedIndex])
  }
}
