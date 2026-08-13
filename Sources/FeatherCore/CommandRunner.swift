import Foundation

public struct CommandOutput: Sendable {
  public let status: Int32
  public let data: Data

  public init(status: Int32, data: Data) {
    self.status = status
    self.data = data
  }

  public var text: String {
    String(decoding: data, as: UTF8.self)
  }
}

public struct CommandFailure: LocalizedError, Sendable {
  public let executable: String
  public let arguments: [String]
  public let status: Int32
  public let output: String

  public var errorDescription: String? {
    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let command = ([executable] + arguments).joined(separator: " ")
    return detail.isEmpty
      ? "Command failed (\(status)): \(command)"
      : "\(detail)\n\nCommand: \(command)"
  }
}

public struct CommandRunner: Sendable {
  public init() {}

  @discardableResult
  public func run(
    _ executable: String,
    arguments: [String] = [],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil,
    allowFailure: Bool = false
  ) throws -> CommandOutput {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = pipe
    process.standardError = pipe
    if let environment {
      process.environment = ProcessInfo.processInfo.environment.merging(environment) {
        _, replacement in replacement
      }
    }

    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let result = CommandOutput(status: process.terminationStatus, data: data)
    if !allowFailure, result.status != 0 {
      throw CommandFailure(
        executable: executable,
        arguments: arguments,
        status: result.status,
        output: result.text
      )
    }
    return result
  }
}
