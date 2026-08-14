import Darwin
import Foundation
import Testing

@testable import FeatherCore

struct BoundedCommandRunnerTests {
  @Test
  func keepsStandardOutputAndErrorSeparate() async throws {
    let output = try await BoundedCommandRunner().run(
      "/bin/zsh",
      arguments: ["-c", "print -n output; print -nu2 error"]
    )
    #expect(output.status == 0)
    #expect(output.stdoutText == "output")
    #expect(output.stderrText == "error")
  }

  @Test
  func stopsAtTheOutputLimit() async {
    await #expect(throws: BoundedCommandError.outputLimit(128)) {
      try await BoundedCommandRunner().run(
        "/usr/bin/yes",
        maximumOutputBytes: 128,
        timeout: 5
      )
    }
  }

  @Test
  func streamsBinaryStandardInputWithoutTextEncoding() async throws {
    let input = Data((0..<1_024 * 1_024).map { UInt8($0 % 251) })
    let output = try await BoundedCommandRunner().run(
      "/bin/cat",
      standardInput: input,
      maximumOutputBytes: input.count + 1,
      timeout: 5
    )

    #expect(output.status == 0)
    #expect(output.stdout == input)
    #expect(output.stderr.isEmpty)
  }

  @Test
  func runsConcurrentPipeBoundCommandsOffTheCooperativeExecutor() async throws {
    let input = Data((0..<256 * 1_024).map { UInt8($0 % 239) })
    let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
      for _ in 0..<12 {
        group.addTask {
          try await BoundedCommandRunner().run(
            "/bin/cat",
            standardInput: input,
            maximumOutputBytes: input.count + 1,
            timeout: 5
          ).stdout
        }
      }
      return try await group.reduce(into: []) { $0.append($1) }
    }

    #expect(outputs.count == 12)
    #expect(outputs.allSatisfy { $0 == input })
  }

  @Test
  func stopsDrainingAfterAExitedCommandLeavesADescendantHoldingItsPipes() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let output = try await BoundedCommandRunner().run(
      "/bin/sh",
      arguments: ["-c", "/bin/sleep 30 & printf 'ready\\n%s' \"$!\""],
      timeout: 5
    )
    let lines = output.stdoutText.split(separator: "\n")
    let descendantPID = lines.count == 2 ? Int32(lines[1]) : nil
    defer {
      if let descendantPID { _ = Darwin.kill(descendantPID, SIGKILL) }
    }

    #expect(output.status == 0)
    #expect(lines.first == "ready")
    #expect(descendantPID != nil)
    #expect(start.duration(to: clock.now) < .seconds(2))
  }
}
