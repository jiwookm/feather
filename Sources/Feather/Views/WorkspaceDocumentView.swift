import AppKit
import FeatherCore
import SwiftUI

@MainActor
final class WorkspaceDocumentController: ObservableObject {
  struct DiffRequest: Equatable {
    let staged: Bool
    let untracked: Bool
    let baseReference: String?

    init(staged: Bool, untracked: Bool, baseReference: String? = nil) {
      self.staged = staged
      self.untracked = untracked
      self.baseReference = baseReference
    }
  }

  struct Request: Equatable {
    let id: UUID
    let rootPath: String
    let path: String
    let diff: DiffRequest?
    let line: Int?

    init(
      id: UUID = UUID(),
      rootPath: String,
      path: String,
      diff: DiffRequest?,
      line: Int? = nil
    ) {
      self.id = id
      self.rootPath = rootPath
      self.path = path
      self.diff = diff
      self.line = line
    }

    static func == (left: Request, right: Request) -> Bool {
      left.rootPath == right.rootPath && left.path == right.path && left.diff == right.diff
        && left.line == right.line
    }
  }

  struct Tab: Identifiable, Equatable {
    let id: UUID
    fileprivate var request: Request

    var title: String { URL(fileURLWithPath: request.path).lastPathComponent }
    var isDiff: Bool { request.diff != nil }
  }

  enum Mode: String {
    case file = "File"
    case diff = "Diff"
  }

  private enum PendingAction {
    case open(Request)
    case select(UUID)
    case close(UUID)
    case closeAll
    case reload
  }

  @Published private(set) var tabs: [Tab] = []
  @Published private(set) var selectedTabID: UUID?
  @Published private(set) var request: Request?
  @Published var mode: Mode = .file
  @Published private(set) var text = ""
  @Published private(set) var diffDocument: UnifiedDiffDocument?
  @Published private(set) var fileError: String?
  @Published private(set) var diffError: String?
  @Published private(set) var message: String?
  @Published private(set) var isLoadingFile = false
  @Published private(set) var isLoadingDiff = false
  @Published private(set) var isSaving = false
  @Published private(set) var isDirty = false
  @Published private(set) var ignoresWhitespace = false
  @Published private(set) var needsUnsavedDecision = false

  private let fileService = WorkspaceFileService()
  private let gitService = GitWorkspaceService()
  private var openedDocument: WorkspaceTextDocument?
  private var originalText = ""
  private var pendingAction: PendingAction?
  private var fileTask: Task<Void, Never>?
  private var diffTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var continuationAfterSave: PendingAction?

  var hasDocument: Bool { !tabs.isEmpty }
  var canEdit: Bool { openedDocument != nil }
  var canSave: Bool { canEdit && isDirty && !isSaving }

  var relativePath: String {
    guard let request else { return "" }
    let prefix = request.rootPath.hasSuffix("/") ? request.rootPath : request.rootPath + "/"
    return request.path.hasPrefix(prefix)
      ? String(request.path.dropFirst(prefix.count)) : request.path
  }

  func openFile(rootPath: String, path: String, line: Int? = nil) {
    requestOpen(Request(rootPath: rootPath, path: path, diff: nil, line: line))
  }

  func openDiff(rootPath: String, file: GitStatusFile, staged: Bool) {
    requestOpen(
      Request(
        rootPath: rootPath,
        path: URL(fileURLWithPath: rootPath).appendingPathComponent(file.path).path,
        diff: DiffRequest(staged: staged, untracked: file.isUntracked)
      )
    )
  }

  func openReviewDiff(
    rootPath: String,
    file: RepositoryReviewFile,
    baseReference: String
  ) {
    requestOpen(
      Request(
        rootPath: rootPath,
        path: URL(fileURLWithPath: rootPath).appendingPathComponent(file.path).path,
        diff: DiffRequest(
          staged: false,
          untracked: file.isUntracked,
          baseReference: baseReference
        )
      )
    )
  }

  func selectTab(_ id: UUID) {
    guard id != selectedTabID, tabs.contains(where: { $0.id == id }) else { return }
    if isDirty {
      presentDecision(for: .select(id))
    } else {
      selectNow(id)
    }
  }

  func replaceText(_ value: String) {
    guard canEdit, value != text else { return }
    text = value
    isDirty = value != originalText
    message = nil
  }

  func showFile() {
    guard canEdit else { return }
    mode = .file
  }

  func showDiff() {
    guard request?.diff != nil else { return }
    mode = .diff
    if diffDocument == nil, !isLoadingDiff { loadDiff() }
  }

  func toggleIgnoredWhitespace() {
    guard request?.diff != nil else { return }
    ignoresWhitespace.toggle()
    loadDiff()
  }

  func save() {
    save(then: nil)
  }

  func reload() {
    if isDirty {
      presentDecision(for: .reload)
    } else {
      reloadNow()
    }
  }

  func requestClose(_ id: UUID? = nil) {
    guard let target = id ?? selectedTabID,
      tabs.contains(where: { $0.id == target })
    else { return }
    if target != selectedTabID {
      tabs.removeAll { $0.id == target }
    } else if isDirty {
      presentDecision(for: .close(target))
    } else {
      closeNow(target)
    }
  }

  func requestCloseAll() {
    guard !tabs.isEmpty else { return }
    if isDirty {
      presentDecision(for: .closeAll)
    } else {
      closeAllNow()
    }
  }

  func saveAndContinue() {
    guard let pendingAction else { return }
    clearPendingDecision()
    if isSaving {
      continuationAfterSave = pendingAction
      return
    }
    save(then: pendingAction)
  }

  func discardAndContinue() {
    guard let action = pendingAction else { return }
    clearPendingDecision()
    execute(action)
  }

  func cancelPendingDecision() {
    clearPendingDecision()
  }

  func setDecisionPresented(_ isPresented: Bool) {
    needsUnsavedDecision = isPresented
  }

  func clearMessage() {
    message = nil
  }

  private func requestOpen(_ next: Request) {
    if let existing = tabs.first(where: {
      $0.request.rootPath == next.rootPath && $0.request.path == next.path
    }) {
      let updated = Request(
        id: existing.id,
        rootPath: next.rootPath,
        path: next.path,
        diff: next.diff,
        line: next.line
      )
      if selectedTabID == existing.id {
        updateTab(updated)
        request = updated
        updateMode(for: updated)
      } else if isDirty {
        presentDecision(for: .open(updated))
      } else {
        openNow(updated)
      }
      return
    }

    if isDirty {
      presentDecision(for: .open(next))
    } else {
      openNow(next)
    }
  }

  private func openNow(_ next: Request) {
    let selectedRequest: Request
    if let existingIndex = tabs.firstIndex(where: {
      $0.request.rootPath == next.rootPath && $0.request.path == next.path
    }) {
      selectedRequest = Request(
        id: tabs[existingIndex].id,
        rootPath: next.rootPath,
        path: next.path,
        diff: next.diff,
        line: next.line
      )
      tabs[existingIndex].request = selectedRequest
    } else {
      selectedRequest = next
      tabs.append(Tab(id: next.id, request: next))
    }
    selectRequestNow(selectedRequest)
  }

  private func selectNow(_ id: UUID) {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    selectRequestNow(tab.request)
  }

  private func selectRequestNow(_ next: Request) {
    cancelTasks()
    selectedTabID = next.id
    request = next
    mode = next.diff == nil ? .file : .diff
    clearLoadedDocument()
    loadFile()
    if next.diff != nil { loadDiff() }
  }

  private func updateTab(_ updated: Request) {
    guard let index = tabs.firstIndex(where: { $0.id == updated.id }) else { return }
    tabs[index].request = updated
  }

  private func updateMode(for updated: Request) {
    if updated.diff == nil {
      mode = .file
      diffTask?.cancel()
      diffTask = nil
      diffDocument = nil
      diffError = nil
      isLoadingDiff = false
    } else {
      mode = .diff
      loadDiff()
    }
  }

  private func loadFile() {
    guard let request else { return }
    let requestID = request.id
    fileTask?.cancel()
    isLoadingFile = true
    fileError = nil
    fileTask = Task { [weak self] in
      guard let self else { return }
      do {
        let document = try await fileService.readTextFile(
          rootPath: request.rootPath,
          filePath: request.path
        )
        guard !Task.isCancelled, self.request?.id == requestID else { return }
        openedDocument = document
        originalText = document.text
        text = document.text
        isDirty = false
      } catch is CancellationError {
        return
      } catch {
        guard self.request?.id == requestID else { return }
        fileError = error.localizedDescription
      }
      guard self.request?.id == requestID else { return }
      isLoadingFile = false
      fileTask = nil
    }
  }

  private func loadDiff() {
    guard let request, let diff = request.diff else { return }
    let requestID = request.id
    let relativePath = relativePath
    diffTask?.cancel()
    isLoadingDiff = true
    diffDocument = nil
    diffError = nil
    diffTask = Task { [weak self] in
      guard let self else { return }
      do {
        let value: String
        if let baseReference = diff.baseReference {
          value = try await gitService.repositoryDiff(
            worktreePath: request.rootPath,
            path: relativePath,
            baseReference: baseReference,
            untracked: diff.untracked,
            ignoreWhitespace: ignoresWhitespace
          )
        } else {
          value = try await gitService.diff(
            worktreePath: request.rootPath,
            path: relativePath,
            staged: diff.staged,
            untracked: diff.untracked,
            ignoreWhitespace: ignoresWhitespace
          )
        }
        guard !Task.isCancelled, self.request?.id == requestID else { return }
        let rendered = value.isEmpty ? "No textual diff is available for this change." : value
        let parsed = await Task.detached(priority: .userInitiated) {
          UnifiedDiffDocument.parse(rendered)
        }.value
        guard !Task.isCancelled, self.request?.id == requestID else { return }
        diffDocument = parsed
      } catch is CancellationError {
        return
      } catch {
        guard self.request?.id == requestID else { return }
        diffError = error.localizedDescription
      }
      guard self.request?.id == requestID else { return }
      isLoadingDiff = false
      diffTask = nil
    }
  }

  private func save(then nextAction: PendingAction?) {
    guard let request, let openedDocument, isDirty, !isSaving else {
      if let nextAction, !isDirty { execute(nextAction) }
      return
    }
    let requestID = request.id
    let value = text
    saveTask?.cancel()
    isSaving = true
    message = nil
    saveTask = Task { [weak self] in
      guard let self else { return }
      do {
        let saved = try await fileService.writeTextFile(
          rootPath: request.rootPath,
          filePath: request.path,
          text: value,
          expectedData: openedDocument.originalData
        )
        guard !Task.isCancelled, self.request?.id == requestID else { return }
        self.openedDocument = saved
        originalText = saved.text
        isDirty = text != originalText
        message = isDirty ? "Saved; newer edits remain unsaved." : "Saved"
        if request.diff != nil { loadDiff() }
        let continuation = nextAction ?? continuationAfterSave
        continuationAfterSave = nil
        if let continuation, !isDirty {
          clearPendingDecision()
          execute(continuation)
        }
      } catch is CancellationError {
        return
      } catch {
        guard self.request?.id == requestID else { return }
        message = error.localizedDescription
      }
      guard self.request?.id == requestID else { return }
      isSaving = false
      saveTask = nil
    }
  }

  private func reloadNow() {
    guard request != nil else { return }
    openedDocument = nil
    originalText = ""
    text = ""
    isDirty = false
    message = nil
    loadFile()
    if request?.diff != nil { loadDiff() }
  }

  private func presentDecision(for action: PendingAction) {
    pendingAction = action
    needsUnsavedDecision = true
  }

  private func clearPendingDecision() {
    pendingAction = nil
    needsUnsavedDecision = false
  }

  private func execute(_ action: PendingAction) {
    switch action {
    case .open(let request): openNow(request)
    case .select(let id): selectNow(id)
    case .close(let id): closeNow(id)
    case .closeAll: closeAllNow()
    case .reload: reloadNow()
    }
  }

  private func closeNow(_ id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let wasSelected = selectedTabID == id
    tabs.remove(at: index)
    guard wasSelected else { return }

    cancelTasks()
    if tabs.isEmpty {
      selectedTabID = nil
      request = nil
      clearLoadedDocument()
      return
    }

    let nextIndex = min(index, tabs.count - 1)
    selectRequestNow(tabs[nextIndex].request)
  }

  private func closeAllNow() {
    cancelTasks()
    tabs.removeAll(keepingCapacity: false)
    selectedTabID = nil
    request = nil
    clearLoadedDocument()
  }

  private func clearLoadedDocument() {
    openedDocument = nil
    originalText = ""
    text = ""
    diffDocument = nil
    fileError = nil
    diffError = nil
    message = nil
    isDirty = false
    ignoresWhitespace = false
  }

  private func cancelTasks() {
    fileTask?.cancel()
    diffTask?.cancel()
    saveTask?.cancel()
    fileTask = nil
    diffTask = nil
    saveTask = nil
    continuationAfterSave = nil
    isLoadingFile = false
    isLoadingDiff = false
    isSaving = false
  }
}

struct WorkspaceDocumentView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openSettings) private var openSettings
  @ObservedObject var controller: WorkspaceDocumentController
  @State private var wrapsLines = true
  @State private var diffLayout = NativeDiffLayout.unified
  let isFullScreen: Bool

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      titlebar
      documentToolbar
      if let message = controller.message { messageBar(message) }
      content
    }
    .background(palette.terminal)
    .confirmationDialog(
      "Save changes to \(controller.relativePath)?",
      isPresented: unsavedDecision,
      titleVisibility: .visible
    ) {
      Button("Save and Continue") { controller.saveAndContinue() }
      Button("Discard Changes", role: .destructive) { controller.discardAndContinue() }
      Button("Cancel", role: .cancel) { controller.cancelPendingDecision() }
    } message: {
      Text("The file has unsaved changes.")
    }
    .onReceive(NotificationCenter.default.publisher(for: .featherSaveDocumentRequested)) { _ in
      controller.save()
    }
  }

  private var titlebar: some View {
    HStack(spacing: 0) {
      if !model.sidebarVisible {
        Button(action: model.toggleSidebar) {
          Image(systemName: "sidebar.left")
            .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(HoverButtonStyle())
        .help("Show Sidebar (⌘S)")
        .padding(.leading, isFullScreen ? 8 : 76)
        .padding(.trailing, 5)
      }

      ScrollView(.horizontal) {
        LazyHStack(spacing: 0) {
          ForEach(controller.tabs) { tab in
            documentTab(tab)
          }
        }
      }
      .scrollIndicators(.never)
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: controller.save) {
        Label(controller.isSaving ? "Saving" : "Save", systemImage: "square.and.arrow.down")
          .font(.feather(size: 11, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .disabled(!controller.canSave)
      .help("Save File (⌘⇧S)")

      Button(action: model.toggleInspector) {
        Image(systemName: "sidebar.right")
          .font(.system(size: 13, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .foregroundStyle(model.inspectorVisible ? palette.primaryText : palette.secondaryText)
      .padding(.leading, 4)
      .help("Toggle Inspector (⌘E)")

      Button(action: openSettings.callAsFunction) {
        Image(systemName: "gearshape")
          .font(.system(size: 13, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .padding(.horizontal, 7)
      .help("Settings… (⌘,)")
    }
    .frame(height: FeatherMetrics.titlebarHeight(isFullScreen))
    .background(palette.titlebar)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.border).frame(height: 1)
    }
    .background(WindowDragSurface())
  }

  private func documentTab(_ tab: WorkspaceDocumentController.Tab) -> some View {
    let selected = controller.selectedTabID == tab.id
    return HStack(spacing: 5) {
      Button {
        controller.selectTab(tab.id)
      } label: {
        HStack(spacing: 7) {
          Image(systemName: tab.isDiff ? "arrow.left.arrow.right" : "doc.text")
            .font(.system(size: 10, weight: .medium))
          Text(tab.title)
            .font(.feather(size: 13, weight: .medium))
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if selected && controller.isDirty {
        Circle().fill(palette.secondaryText).frame(width: 6, height: 6)
      }
      Button {
        controller.requestClose(tab.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .frame(width: 16, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close (tab.title)")
    }
    .foregroundStyle(selected ? palette.primaryText : palette.secondaryText)
    .padding(.leading, 11)
    .padding(.trailing, 7)
    .frame(minWidth: 118, idealWidth: 158, maxWidth: 190)
    .frame(height: FeatherMetrics.titlebarHeight(isFullScreen) - 1)
    .background(selected ? palette.terminal : palette.titlebar)
    .overlay(alignment: .trailing) {
      Rectangle().fill(palette.border).frame(width: 1)
    }
  }

  private var documentToolbar: some View {
    HStack(spacing: 8) {
      breadcrumbs
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(-1)
      if controller.request?.diff != nil {
        modeButton(.file, enabled: controller.canEdit)
        modeButton(.diff, enabled: true)
      }
      if controller.mode == .diff, let document = controller.diffDocument {
        Text("+\(document.additions)")
          .foregroundStyle(Color(hex: 0xADDB67))
        Text("−\(document.deletions)")
          .foregroundStyle(Color(hex: 0xEF5350))
        diffLayoutControl
        Button(action: controller.toggleIgnoredWhitespace) {
          Image(systemName: "paragraphsign")
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(HoverButtonStyle())
        .foregroundStyle(
          controller.ignoresWhitespace ? palette.primaryText : palette.secondaryText
        )
        .help(
          controller.ignoresWhitespace ? "Show Whitespace Changes" : "Hide Whitespace Changes"
        )
      }
      Button {
        if controller.mode != .diff { wrapsLines.toggle() }
      } label: {
        Image(systemName: "text.word.spacing")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .foregroundStyle(
        controller.mode == .diff || wrapsLines ? palette.primaryText : palette.secondaryText
      )
      .disabled(controller.mode == .diff)
      .help(
        controller.mode == .diff
          ? "Diffs always wrap to fit the available width"
          : (wrapsLines ? "Disable Word Wrap" : "Enable Word Wrap")
      )
      Button(action: controller.reload) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .help("Reload from Disk")
      Button {
        guard let path = controller.request?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      } label: {
        Image(systemName: "finder")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(HoverButtonStyle())
      .help("Reveal in Finder")
    }
    .padding(.horizontal, 10)
    .font(.feather(size: 10, weight: .medium))
    .frame(height: 36)
    .background(palette.titlebar)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.border.opacity(0.65)).frame(height: 1)
    }
  }

  private var breadcrumbs: some View {
    let root =
      controller.request.map {
        URL(fileURLWithPath: $0.rootPath).lastPathComponent
      } ?? ""
    let components = controller.relativePath.split(separator: "/").map(String.init)
    return ScrollView(.horizontal) {
      HStack(spacing: 3) {
        Text(root)
          .foregroundStyle(palette.mutedText)
        ForEach(Array(components.enumerated()), id: \.offset) { index, component in
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(palette.mutedText)
          Text(component)
            .foregroundStyle(
              index == components.count - 1 ? palette.primaryText : palette.mutedText)
        }
      }
      .lineLimit(1)
    }
    .scrollIndicators(.never)
  }

  private var diffLayoutControl: some View {
    HStack(spacing: 0) {
      ForEach(NativeDiffLayout.allCases) { layout in
        Button {
          diffLayout = layout
        } label: {
          Image(systemName: layout == .unified ? "rectangle.split.1x2" : "rectangle.split.2x1")
            .font(.system(size: 10, weight: .medium))
            .frame(width: 24, height: 22)
            .background(diffLayout == layout ? palette.selection : .clear)
        }
        .buttonStyle(.plain)
        .foregroundStyle(diffLayout == layout ? palette.primaryText : palette.secondaryText)
        .help("\(layout.rawValue) Diff")
      }
    }
    .background(palette.terminal.opacity(0.45))
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }

  @ViewBuilder
  private var content: some View {
    switch controller.mode {
    case .file:
      if controller.isLoadingFile {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = controller.fileError {
        failureView(error, retry: controller.reload)
      } else if controller.canEdit {
        NativeCodeTextView(
          text: Binding(
            get: { controller.text },
            set: { value in controller.replaceText(value) }
          ),
          path: controller.relativePath,
          isDark: colorScheme == .dark,
          wrapsLines: wrapsLines,
          revealLine: controller.request?.line
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      }
    case .diff:
      if controller.isLoadingDiff {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = controller.diffError {
        failureView(error) { controller.showDiff() }
      } else if let document = controller.diffDocument {
        NativeDiffViewer(
          document: document,
          path: controller.relativePath,
          isDark: colorScheme == .dark,
          layout: diffLayout
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      }
    }
  }

  private func modeButton(_ mode: WorkspaceDocumentController.Mode, enabled: Bool) -> some View {
    Button(mode.rawValue) {
      if mode == .file {
        controller.showFile()
      } else {
        controller.showDiff()
      }
    }
    .buttonStyle(.plain)
    .font(.feather(size: 10, weight: .medium))
    .foregroundStyle(controller.mode == mode ? palette.primaryText : palette.secondaryText)
    .padding(.horizontal, 8)
    .frame(height: 24)
    .background(controller.mode == mode ? palette.selection : .clear)
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .disabled(!enabled)
  }

  private func messageBar(_ message: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: message == "Saved" ? "checkmark.circle" : "info.circle")
      Text(message).lineLimit(2)
      Spacer(minLength: 0)
      Button(action: controller.clearMessage) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
    }
    .font(.feather(size: 10))
    .foregroundStyle(palette.secondaryText)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(palette.selection.opacity(0.55))
  }

  private func failureView(_ message: String, retry: @escaping () -> Void) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 20, weight: .light))
        .foregroundStyle(palette.mutedText)
      Text(message)
        .font(.feather(size: 11))
        .foregroundStyle(palette.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      Button("Try Again", action: retry)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var unsavedDecision: Binding<Bool> {
    Binding(
      get: { controller.needsUnsavedDecision },
      set: { isPresented in controller.setDecisionPresented(isPresented) }
    )
  }
}
