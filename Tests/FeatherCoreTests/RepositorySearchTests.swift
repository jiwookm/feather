import Foundation
import Testing

@testable import FeatherCore

struct RepositorySearchTests {
  @Test
  func searchesAWorkingCopyWithoutBuildingAnIndex() async throws {
    guard let ripgrep = RepositorySearchService.locateExecutable() else { return }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("feather-search-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("let FeatherNeedle = true\n".utf8).write(to: root.appendingPathComponent("App.swift"))

    let snapshot = try await RepositorySearchService(ripgrepExecutable: ripgrep).search(
      worktreePath: root.path,
      query: "FeatherNeedle"
    )

    #expect(snapshot.matches.map(\.path) == ["App.swift"])
    #expect(snapshot.matches.first?.line == 1)
  }

  @Test
  func parsesMatchEventsAndBoundsResults() {
    let json = """
      {"type":"begin","data":{"path":{"text":"./Sources/App.swift"}}}
      {"type":"match","data":{"path":{"text":"./Sources/App.swift"},"lines":{"text":"let feather = true\\n"},"line_number":12,"absolute_offset":40,"submatches":[{"match":{"text":"feather"},"start":4,"end":11}]}}
      {"type":"match","data":{"path":{"text":"README.md"},"lines":{"text":"Feather is native\\n"},"line_number":3,"absolute_offset":10,"submatches":[{"match":{"text":"Feather"},"start":0,"end":7}]}}
      {"type":"summary","data":{"stats":{}}}
      """

    let snapshot = RipgrepJSONParser.parse(Data(json.utf8), maximumResults: 1)

    #expect(snapshot.matches.count == 1)
    #expect(snapshot.isTruncated)
    #expect(snapshot.matches[0].path == "Sources/App.swift")
    #expect(snapshot.matches[0].line == 12)
    #expect(snapshot.matches[0].column == 5)
    #expect(snapshot.matches[0].preview == "let feather = true")
  }

  @Test
  func ignoresMalformedAndNonMatchEvents() {
    let json = """
      not-json
      {"type":"context","data":{"path":{"text":"README.md"}}}
      {"type":"match","data":{"path":{"bytes":"AA=="},"lines":{"text":"ignored"},"line_number":1,"submatches":[]}}
      """

    let snapshot = RipgrepJSONParser.parse(Data(json.utf8))

    #expect(snapshot.matches.isEmpty)
    #expect(!snapshot.isTruncated)
  }
}
