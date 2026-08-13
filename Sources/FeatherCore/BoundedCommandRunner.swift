import Darwin
import Dispatch
import Foundation

public struct BoundedCommandOutput: Sendable {
  public let status: Int32
  public let stdout: Data
  public let stderr: Data

  public init(status: Int32, stdout: Data, stderr: Data) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }

  public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
  public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum BoundedCommandError: LocalizedError, Equatable, Sendable {
  case outputLimit(Int)
  case timedOut(TimeInterval)

  public var errorDescription: String? {
    switch self {
    case .outputLimit(let bytes):
      "Command output exceeded Feather's \(bytes)-byte safety limit."
    case .timedOut(let seconds):
      "Command did not finish within \(Int(seconds)) seconds."
    }
  }
}

public struct BoundedCommandFailure: LocalizedError, Sendable {
  public let executable: String
  public let arguments: [String]
  public let status: Int32
  public let stderr: String

  public var errorDescription: String? {
    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty
      ? "Command failed with status \(status): \(executable)"
      : detail
  }
}

/// Runs a subprocess off the cooperative executor while bounding both output
/// and runtime. Cancellation terminates the child instead of leaving hidden
/// Git or GitHub work behind after the inspector disappears.
public struct BoundedCommandRunner: Sendable {
  public init() {}

  public func run(
    _ executable: String,
    arguments: [String] = [],
    currentDirectory: URL? = nil,
    environment: [String: String] = [:],
    maximumOutputBytes: Int = 8 * 1_024 * 1_024,
    timeout: TimeInterval = 15
  ) async throws -> BoundedCommandOutput {
    let execution = CommandExecution(
      executable: executable,
      arguments: arguments,
      currentDirectory: currentDirectory,
      environment: environment,
      maximumOutputBytes: maximumOutputBytes,
      timeout: timeout
    )
    return try await withTaskCancellationHandler {
      try await Task.detached(priority: .utility) {
        try execution.execute()
      }.value
    } onCancel: {
      execution.cancel()
    }
  }
}

private final class CommandExecution: @unchecked Sendable {
  private enum StopReason {
    case cancelled
    case outputLimit
    case timeout
  }

  private let executable: String
  private let arguments: [String]
  private let currentDirectory: URL?
  private let environment: [String: String]
  private let maximumOutputBytes: Int
  private let timeout: TimeInterval
  private let lock = NSLock()
  private var process: Process?
  private var stdout = Data()
  private var stderr = Data()
  private var stopReason: StopReason?

  init(
    executable: String,
    arguments: [String],
    currentDirectory: URL?,
    environment: [String: String],
    maximumOutputBytes: Int,
    timeout: TimeInterval
  ) {
    self.executable = executable
    self.arguments = arguments
    self.currentDirectory = currentDirectory
    self.environment = environment
    self.maximumOutputBytes = max(1, maximumOutputBytes)
    self.timeout = max(0.1, timeout)
  }

  func execute() throws -> BoundedCommandOutput {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.environment = ProcessInfo.processInfo.environment.merging(environment) {
      _, replacement in replacement
    }

    lock.lock()
    self.process = process
    let cancelledBeforeStart = stopReason == .cancelled
    lock.unlock()
    if cancelledBeforeStart { throw CancellationError() }

    try process.run()

    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async { [self] in
      read(outputPipe.fileHandleForReading, isStandardError: false)
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async { [self] in
      read(errorPipe.fileHandleForReading, isStandardError: true)
      readers.leave()
    }

    let timeoutWork = DispatchWorkItem { [weak self] in
      self?.stop(.timeout)
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout,
      execute: timeoutWork
    )

    process.waitUntilExit()
    readers.wait()
    timeoutWork.cancel()

    lock.lock()
    self.process = nil
    let result = BoundedCommandOutput(
      status: process.terminationStatus,
      stdout: stdout,
      stderr: stderr
    )
    let reason = stopReason
    lock.unlock()

    switch reason {
    case .cancelled: throw CancellationError()
    case .outputLimit: throw BoundedCommandError.outputLimit(maximumOutputBytes)
    case .timeout: throw BoundedCommandError.timedOut(timeout)
    case nil: return result
    }
  }

  func cancel() {
    stop(.cancelled)
  }

  private func read(_ handle: FileHandle, isStandardError: Bool) {
    while true {
      let data = (try? handle.read(upToCount: 64 * 1_024)) ?? Data()
      guard !data.isEmpty else { return }
      append(data, isStandardError: isStandardError)
    }
  }

  private func append(_ data: Data, isStandardError: Bool) {
    lock.lock()
    let remaining = maximumOutputBytes - stdout.count - stderr.count
    if remaining > 0 {
      if isStandardError {
        stderr.append(data.prefix(remaining))
      } else {
        stdout.append(data.prefix(remaining))
      }
    }
    let exceeded = data.count > remaining && stopReason == nil
    if exceeded { stopReason = .outputLimit }
    let runningProcess = exceeded ? process : nil
    lock.unlock()
    if let runningProcess { terminate(runningProcess) }
  }

  private func stop(_ reason: StopReason) {
    lock.lock()
    if stopReason == nil { stopReason = reason }
    let runningProcess = process
    lock.unlock()
    if let runningProcess { terminate(runningProcess) }
  }

  private func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let identifier = process.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
      if process.isRunning { Darwin.kill(identifier, SIGKILL) }
    }
  }
}
