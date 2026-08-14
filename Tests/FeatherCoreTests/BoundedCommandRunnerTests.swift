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
}
