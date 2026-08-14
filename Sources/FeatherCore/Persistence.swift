import Foundation

public struct JSONStateStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func applicationSupportURL(
    directoryName: String = "Feather",
    legacyDirectoryName: String? = "Barnacle",
    fileManager: FileManager = .default
  ) throws -> URL {
    guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return applicationSupportURL(
      in: root,
      directoryName: directoryName,
      legacyDirectoryName: legacyDirectoryName,
      fileManager: fileManager
    )
  }

  static func applicationSupportURL(
    in root: URL,
    directoryName: String = "Feather",
    legacyDirectoryName: String? = "Barnacle",
    fileManager: FileManager = .default
  ) -> URL {
    let current = root.appendingPathComponent(directoryName, isDirectory: true)
    guard let legacyDirectoryName else { return current }

    let legacy = root.appendingPathComponent(legacyDirectoryName, isDirectory: true)
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

  public static func live(
    directoryName: String = "Feather",
    legacyDirectoryName: String? = "Barnacle",
    fileManager: FileManager = .default
  ) throws -> JSONStateStore {
    let root = try applicationSupportURL(
      directoryName: directoryName,
      legacyDirectoryName: legacyDirectoryName,
      fileManager: fileManager
    )
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
