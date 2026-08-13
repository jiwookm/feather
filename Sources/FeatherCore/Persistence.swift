import Foundation

public struct JSONStateStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func applicationSupportURL(fileManager: FileManager = .default) throws -> URL {
    guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return applicationSupportURL(in: root, fileManager: fileManager)
  }

  static func applicationSupportURL(
    in root: URL,
    fileManager: FileManager = .default
  ) -> URL {
    let current = root.appendingPathComponent("Feather", isDirectory: true)
    let legacy = root.appendingPathComponent("Barnacle", isDirectory: true)
    guard !fileManager.fileExists(atPath: current.path),
      fileManager.fileExists(atPath: legacy.path)
    else { return current }

    do {
      try fileManager.moveItem(at: legacy, to: current)
      return current
    } catch {
      // Keep using the existing data if a one-time directory rename cannot complete.
      return legacy
    }
  }

  public static func live(fileManager: FileManager = .default) throws -> JSONStateStore {
    let root = try applicationSupportURL(fileManager: fileManager)
    return JSONStateStore(fileURL: root.appendingPathComponent("state.json"))
  }

  public func load(fileManager: FileManager = .default) throws -> ApplicationSnapshot {
    guard fileManager.fileExists(atPath: fileURL.path) else { return ApplicationSnapshot() }
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(ApplicationSnapshot.self, from: data)
  }

  public func save(_ snapshot: ApplicationSnapshot, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(snapshot)
    try data.write(to: fileURL, options: .atomic)
  }
}
