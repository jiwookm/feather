import Foundation

public struct WorkspaceFileEntry: Equatable, Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let name: String
  public let isDirectory: Bool
  public let isSymbolicLink: Bool

  public init(path: String, name: String, isDirectory: Bool, isSymbolicLink: Bool) {
    self.path = path
    self.name = name
    self.isDirectory = isDirectory
    self.isSymbolicLink = isSymbolicLink
  }
}

public struct WorkspaceDirectoryListing: Equatable, Sendable {
  public let entries: [WorkspaceFileEntry]
  public let isTruncated: Bool

  public init(entries: [WorkspaceFileEntry], isTruncated: Bool) {
    self.entries = entries
    self.isTruncated = isTruncated
  }
}

public struct WorkspaceTextDocument: Equatable, Sendable {
  public let path: String
  public let text: String
  public let originalData: Data

  public init(path: String, text: String, originalData: Data) {
    self.path = path
    self.text = text
    self.originalData = originalData
  }
}

public enum WorkspaceFileError: LocalizedError, Equatable, Sendable {
  case outsideRoot
  case notDirectory(String)
  case notRegularFile(String)
  case fileTooLarge(Int)
  case notUTF8(String)
  case changedOnDisk(String)

  public var errorDescription: String? {
    switch self {
    case .outsideRoot:
      "Feather refused to browse outside the selected worktree."
    case .notDirectory(let path):
      "The folder is unavailable: \(path)"
    case .notRegularFile(let path):
      "Feather can edit only regular files inside the selected worktree: \(path)"
    case .fileTooLarge(let maximumBytes):
      "This file exceeds Feather's \(maximumBytes / 1_024 / 1_024) MB editor limit."
    case .notUTF8(let path):
      "This is not a UTF-8 text file: \(path)"
    case .changedOnDisk(let path):
      "The file changed on disk after it was opened. Reload it before saving: \(path)"
    }
  }
}

/// Reads exactly one directory per request. It deliberately owns no watcher,
/// index, recursive scan, or cache; the visible SwiftUI tree is the cache.
public actor WorkspaceFileService {
  public init() {}

  public func listDirectory(
    rootPath: String,
    directoryPath: String,
    limit: Int = 2_000
  ) throws -> WorkspaceDirectoryListing {
    try Task.checkCancellation()
    let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
    guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
      throw WorkspaceFileError.outsideRoot
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw WorkspaceFileError.notDirectory(directory.path)
    }

    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
        errorHandler: { _, _ in true }
      )
    else {
      throw WorkspaceFileError.notDirectory(directory.path)
    }

    var entries: [WorkspaceFileEntry] = []
    entries.reserveCapacity(min(limit, 256))
    var truncated = false
    for case let child as URL in enumerator {
      try Task.checkCancellation()
      let name = child.lastPathComponent
      if name == ".git" || name == ".DS_Store" { continue }
      if entries.count == limit {
        truncated = true
        break
      }
      let values = try? child.resourceValues(forKeys: Set(keys))
      let symbolicLink = values?.isSymbolicLink == true
      entries.append(
        WorkspaceFileEntry(
          path: child.standardizedFileURL.path,
          name: name,
          isDirectory: values?.isDirectory == true && !symbolicLink,
          isSymbolicLink: symbolicLink
        )
      )
    }

    entries.sort { left, right in
      if left.isDirectory != right.isDirectory { return left.isDirectory }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
    return WorkspaceDirectoryListing(entries: entries, isTruncated: truncated)
  }

  public func readTextFile(
    rootPath: String,
    filePath: String,
    maximumBytes: Int = 2 * 1_024 * 1_024
  ) throws -> WorkspaceTextDocument {
    try Task.checkCancellation()
    let file = try validatedRegularFile(rootPath: rootPath, filePath: filePath)
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maximumBytes else { throw WorkspaceFileError.fileTooLarge(maximumBytes) }

    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    guard data.count <= maximumBytes else { throw WorkspaceFileError.fileTooLarge(maximumBytes) }
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
      throw WorkspaceFileError.notUTF8(file.path)
    }
    return WorkspaceTextDocument(path: file.path, text: text, originalData: data)
  }

  public func writeTextFile(
    rootPath: String,
    filePath: String,
    text: String,
    expectedData: Data,
    maximumBytes: Int = 2 * 1_024 * 1_024
  ) throws -> WorkspaceTextDocument {
    try Task.checkCancellation()
    let file = try validatedRegularFile(rootPath: rootPath, filePath: filePath)
    let currentData = try Data(contentsOf: file, options: .mappedIfSafe)
    guard currentData == expectedData else { throw WorkspaceFileError.changedOnDisk(file.path) }

    let nextData = Data(text.utf8)
    guard nextData.count <= maximumBytes else {
      throw WorkspaceFileError.fileTooLarge(maximumBytes)
    }
    try nextData.write(to: file, options: .atomic)
    return WorkspaceTextDocument(path: file.path, text: text, originalData: nextData)
  }

  private func validatedRegularFile(rootPath: String, filePath: String) throws -> URL {
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let requested = URL(fileURLWithPath: filePath).standardizedFileURL
    let requestedValues = try requested.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard requestedValues.isSymbolicLink != true else {
      throw WorkspaceFileError.notRegularFile(requested.path)
    }

    let file = requested.resolvingSymlinksInPath()
    guard file.path.hasPrefix(root.path + "/") else { throw WorkspaceFileError.outsideRoot }
    let values = try file.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      throw WorkspaceFileError.notRegularFile(file.path)
    }
    return file
  }
}
