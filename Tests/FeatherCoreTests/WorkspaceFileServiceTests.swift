import Foundation
import Testing

@testable import FeatherCore

struct WorkspaceFileServiceTests {
  @Test
  func listsOnlyOneLevelAndSortsDirectoriesFirst() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-files-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("nested/deeper", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("b".utf8).write(to: root.appendingPathComponent("b.txt"))
    try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data().write(to: root.appendingPathComponent(".git"))

    let listing = try await WorkspaceFileService().listDirectory(
      rootPath: root.path,
      directoryPath: root.path
    )

    #expect(listing.entries.map(\.name) == ["nested", "a.txt", "b.txt"])
    #expect(listing.entries.first?.isDirectory == true)
    #expect(!listing.entries.contains { $0.name == "deeper" })
  }

  @Test
  func refusesPathsOutsideTheRootAndCapsResults() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-files-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<4 {
      try Data().write(to: root.appendingPathComponent("\(index).txt"))
    }

    let service = WorkspaceFileService()
    let listing = try await service.listDirectory(
      rootPath: root.path,
      directoryPath: root.path,
      limit: 2
    )
    #expect(listing.entries.count == 2)
    #expect(listing.isTruncated)

    await #expect(throws: WorkspaceFileError.outsideRoot) {
      try await service.listDirectory(
        rootPath: root.path,
        directoryPath: root.deletingLastPathComponent().path
      )
    }
  }

  @Test
  func readsAndSafelySavesTextWithoutChangingExecutablePermission() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-editor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("script.sh")
    try Data("#!/bin/sh\necho before\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

    let service = WorkspaceFileService()
    let opened = try await service.readTextFile(rootPath: root.path, filePath: file.path)
    #expect(opened.text == "#!/bin/sh\necho before\n")

    let saved = try await service.writeTextFile(
      rootPath: root.path,
      filePath: file.path,
      text: "#!/bin/sh\necho after\n",
      expectedData: opened.originalData
    )

    #expect(saved.text == "#!/bin/sh\necho after\n")
    #expect(try String(contentsOf: file, encoding: .utf8) == saved.text)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
  }

  @Test
  func refusesToOverwriteAnExternalEdit() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-editor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("source.swift")
    try Data("let value = 1\n".utf8).write(to: file)

    let service = WorkspaceFileService()
    let opened = try await service.readTextFile(rootPath: root.path, filePath: file.path)
    try Data("let value = 2\n".utf8).write(to: file)

    await #expect(throws: WorkspaceFileError.changedOnDisk(file.path)) {
      try await service.writeTextFile(
        rootPath: root.path,
        filePath: file.path,
        text: "let value = 3\n",
        expectedData: opened.originalData
      )
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 2\n")
  }

  @Test
  func refusesBinaryOversizedAndEscapingFiles() async throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-editor-\(UUID().uuidString)", isDirectory: true)
    let root = parent.appendingPathComponent("root", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binary = root.appendingPathComponent("binary")
    let large = root.appendingPathComponent("large.txt")
    let outside = parent.appendingPathComponent("outside.txt")
    try Data([0, 1, 2]).write(to: binary)
    try Data(repeating: 65, count: 9).write(to: large)
    try Data("outside".utf8).write(to: outside)

    let service = WorkspaceFileService()
    await #expect(throws: WorkspaceFileError.notUTF8(binary.path)) {
      try await service.readTextFile(rootPath: root.path, filePath: binary.path)
    }
    await #expect(throws: WorkspaceFileError.fileTooLarge(8)) {
      try await service.readTextFile(rootPath: root.path, filePath: large.path, maximumBytes: 8)
    }
    await #expect(throws: WorkspaceFileError.outsideRoot) {
      try await service.readTextFile(rootPath: root.path, filePath: outside.path)
    }
  }
}
