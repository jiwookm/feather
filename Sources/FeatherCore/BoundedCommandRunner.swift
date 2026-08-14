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

  static func hasElapsed(
    _ duration: UInt64,
    since start: UInt64,
    at current: UInt64
  ) -> Bool {
    guard current >= start else { return false }
    return current - start >= duration
  }

  public func run(
    _ executable: String,
    arguments: [String] = [],
    currentDirectory: URL? = nil,
    environment: [String: String] = [:],
    standardInput: Data? = nil,
    maximumOutputBytes: Int = 8 * 1_024 * 1_024,
    timeout: TimeInterval = 15
  ) async throws -> BoundedCommandOutput {
    let execution = CommandExecution(
      executable: executable,
      arguments: arguments,
      currentDirectory: currentDirectory,
      environment: environment,
      standardInput: standardInput,
      maximumOutputBytes: maximumOutputBytes,
      timeout: timeout
    )
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
          do {
            continuation.resume(returning: try execution.execute())
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
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
  private let standardInput: Data?
  private let maximumOutputBytes: Int
  private let timeout: TimeInterval
  private let lock = NSLock()
  private var process: Process?
  private var stdout = Data()
  private var stderr = Data()
  private var stopReason: StopReason?
  private var processExitUptime: UInt64?

  /// A direct child owns its output through exit. A daemonized descendant may
  /// inherit the same descriptors indefinitely, so only give already-buffered
  /// bytes a short, deterministic window to drain after that exit.
  private let maximumPostExitDrainNanoseconds: UInt64 = 2_000_000_000
  private let idlePostExitDrainNanoseconds: UInt64 = 100_000_000

  init(
    executable: String,
    arguments: [String],
    currentDirectory: URL?,
    environment: [String: String],
    standardInput: Data?,
    maximumOutputBytes: Int,
    timeout: TimeInterval
  ) {
    self.executable = executable
    self.arguments = arguments
    self.currentDirectory = currentDirectory
    self.environment = environment
    self.standardInput = standardInput
    self.maximumOutputBytes = max(1, maximumOutputBytes)
    self.timeout = max(0.1, timeout)
  }

  func execute() throws -> BoundedCommandOutput {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = standardInput.map { _ in Pipe() }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.standardInput = inputPipe ?? FileHandle.nullDevice
    process.environment = ProcessInfo.processInfo.environment.merging(environment) {
      _, replacement in replacement
    }

    lock.lock()
    self.process = process
    let cancelledBeforeStart = stopReason == .cancelled
    lock.unlock()
    if cancelledBeforeStart { throw CancellationError() }

    do {
      try process.run()
    } catch {
      lock.lock()
      self.process = nil
      processExitUptime = DispatchTime.now().uptimeNanoseconds
      lock.unlock()
      throw error
    }

    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()

    let writers = DispatchGroup()
    if let standardInput, let inputPipe {
      try? inputPipe.fileHandleForReading.close()
      writers.enter()
      Thread.detachNewThread { [self] in
        write(standardInput, to: inputPipe.fileHandleForWriting)
        writers.leave()
      }
    }

    let readers = DispatchGroup()
    readers.enter()
    Thread.detachNewThread { [self] in
      read(outputPipe.fileHandleForReading, isStandardError: false)
      readers.leave()
    }
    readers.enter()
    Thread.detachNewThread { [self] in
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
    timeoutWork.cancel()
    lock.lock()
    processExitUptime = DispatchTime.now().uptimeNanoseconds
    lock.unlock()
    readers.wait()
    writers.wait()
    try? outputPipe.fileHandleForReading.close()
    try? errorPipe.fileHandleForReading.close()

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
    let descriptor = handle.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var idleAfterExitUptime: UInt64?

    while true {
      let exitUptime = directProcessExitUptime()
      let now = DispatchTime.now().uptimeNanoseconds
      if let exitUptime,
        BoundedCommandRunner.hasElapsed(
          maximumPostExitDrainNanoseconds,
          since: exitUptime,
          at: now
        )
      {
        return
      }
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        idleAfterExitUptime = nil
        append(Data(buffer.prefix(count)), isStandardError: isStandardError)
        continue
      }
      if count == 0 { return }
      if errno == EINTR { continue }
      guard errno == EAGAIN || errno == EWOULDBLOCK else { return }
      if exitUptime != nil {
        if let idleAfterExitUptime,
          BoundedCommandRunner.hasElapsed(
            idlePostExitDrainNanoseconds,
            since: idleAfterExitUptime,
            at: now
          )
        {
          return
        }
        idleAfterExitUptime = idleAfterExitUptime ?? now
      }
      usleep(10_000)
    }
  }

  private func write(_ data: Data, to handle: FileHandle) {
    defer { try? handle.close() }
    let descriptor = handle.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)

    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        if shouldStopWriting() { return }
        let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
          continue
        }
        if count == -1, errno == EINTR { continue }
        if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
          usleep(10_000)
          continue
        }
        return
      }
    }
  }

  private func directProcessExitUptime() -> UInt64? {
    lock.lock()
    let exitUptime = processExitUptime
    lock.unlock()
    return exitUptime
  }

  private func shouldStopWriting() -> Bool {
    lock.lock()
    let stopped = stopReason != nil || processExitUptime != nil
    lock.unlock()
    return stopped
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
