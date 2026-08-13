import Foundation
import Testing

@testable import Feather

struct WorkspaceDocumentControllerTests {
  @Test @MainActor
  func editsSavesAndProtectsUnsavedChanges() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-document-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("first.swift")
    let second = root.appendingPathComponent("second.swift")
    try Data("let first = 1\n".utf8).write(to: first)
    try Data("let second = 2\n".utf8).write(to: second)

    let controller = WorkspaceDocumentController()
    controller.openFile(rootPath: root.path, path: first.path)
    try await eventually { controller.canEdit }

    controller.replaceText("let first = 3\n")
    #expect(controller.isDirty)
    controller.save()
    try await eventually { !controller.isDirty && !controller.isSaving }
    #expect(try String(contentsOf: first, encoding: .utf8) == "let first = 3\n")

    controller.replaceText("unsaved\n")
    controller.openFile(rootPath: root.path, path: second.path)
    #expect(controller.needsUnsavedDecision)
    #expect(controller.request?.path == first.path)

    controller.discardAndContinue()
    try await eventually { controller.canEdit && controller.request?.path == second.path }
    #expect(controller.text == "let second = 2\n")
  }

  @Test @MainActor
  func keepsOnlyTheSelectedTabLoadedAndClosesPredictably() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-tabs-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("first.swift")
    let second = root.appendingPathComponent("second.swift")
    try Data("first\n".utf8).write(to: first)
    try Data("second\n".utf8).write(to: second)

    let controller = WorkspaceDocumentController()
    controller.openFile(rootPath: root.path, path: first.path)
    try await eventually { controller.text == "first\n" }
    let firstID = try #require(controller.selectedTabID)

    controller.openFile(rootPath: root.path, path: second.path)
    try await eventually { controller.text == "second\n" }
    #expect(controller.tabs.map(\.title) == ["first.swift", "second.swift"])
    #expect(controller.selectedTabID != firstID)

    controller.selectTab(firstID)
    try await eventually { controller.text == "first\n" }
    #expect(controller.tabs.count == 2)

    controller.requestClose(firstID)
    try await eventually { controller.text == "second\n" }
    #expect(controller.tabs.map(\.title) == ["second.swift"])
  }

  @MainActor
  private func eventually(
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for document state")
  }
}
