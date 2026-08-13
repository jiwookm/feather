import Foundation

public struct UnifiedDiffDocument: Equatable, Sendable {
  public struct Line: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      case metadata
      case hunk
      case context
      case addition
      case deletion
    }

    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?

    public init(kind: Kind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
      self.kind = kind
      self.text = text
      self.oldLine = oldLine
      self.newLine = newLine
    }
  }

  public struct SplitRow: Equatable, Sendable {
    public let left: Line?
    public let right: Line?

    public init(left: Line?, right: Line?) {
      self.left = left
      self.right = right
    }
  }

  public let lines: [Line]
  public let additions: Int
  public let deletions: Int

  public init(lines: [Line], additions: Int, deletions: Int) {
    self.lines = lines
    self.additions = additions
    self.deletions = deletions
  }

  public static func parse(_ patch: String) -> UnifiedDiffDocument {
    var rawLines = patch.split(separator: "\n", omittingEmptySubsequences: false)
    if patch.hasSuffix("\n"), rawLines.last?.isEmpty == true {
      rawLines.removeLast()
    }
    var lines: [Line] = []
    lines.reserveCapacity(rawLines.count)
    var oldLine: Int?
    var newLine: Int?
    var additions = 0
    var deletions = 0

    for rawLine in rawLines {
      let value = String(rawLine)
      if value.hasPrefix("diff --git ") {
        oldLine = nil
        newLine = nil
        lines.append(Line(kind: .metadata, text: value))
      } else if value.hasPrefix("--- ") || value.hasPrefix("+++ ")
        || value.hasPrefix("\\ No newline")
      {
        lines.append(Line(kind: .metadata, text: value))
      } else if value.hasPrefix("@@"), let start = hunkStart(value) {
        oldLine = start.old
        newLine = start.new
        lines.append(Line(kind: .hunk, text: value))
      } else if oldLine != nil, value.hasPrefix("+") {
        lines.append(Line(kind: .addition, text: String(value.dropFirst()), newLine: newLine))
        newLine = newLine.map { $0 + 1 }
        additions += 1
      } else if oldLine != nil, value.hasPrefix("-") {
        lines.append(Line(kind: .deletion, text: String(value.dropFirst()), oldLine: oldLine))
        oldLine = oldLine.map { $0 + 1 }
        deletions += 1
      } else if oldLine != nil, value.hasPrefix(" ") {
        lines.append(
          Line(
            kind: .context,
            text: String(value.dropFirst()),
            oldLine: oldLine,
            newLine: newLine
          )
        )
        oldLine = oldLine.map { $0 + 1 }
        newLine = newLine.map { $0 + 1 }
      } else {
        lines.append(Line(kind: .metadata, text: value))
      }
    }

    return UnifiedDiffDocument(lines: lines, additions: additions, deletions: deletions)
  }

  public var splitRows: [SplitRow] {
    var rows: [SplitRow] = []
    rows.reserveCapacity(lines.count)
    var index = 0

    while index < lines.count {
      let line = lines[index]
      if line.kind == .addition {
        rows.append(SplitRow(left: nil, right: line))
        index += 1
        continue
      }
      guard line.kind == .deletion else {
        rows.append(SplitRow(left: line, right: line))
        index += 1
        continue
      }

      var deletions: [Line] = []
      while index < lines.count, lines[index].kind == .deletion {
        deletions.append(lines[index])
        index += 1
      }
      var additions: [Line] = []
      while index < lines.count, lines[index].kind == .addition {
        additions.append(lines[index])
        index += 1
      }
      let pairCount = max(deletions.count, additions.count)
      for pairIndex in 0..<pairCount {
        rows.append(
          SplitRow(
            left: deletions.indices.contains(pairIndex) ? deletions[pairIndex] : nil,
            right: additions.indices.contains(pairIndex) ? additions[pairIndex] : nil
          )
        )
      }
    }

    return rows
  }

  private static func hunkStart(_ line: String) -> (old: Int, new: Int)? {
    guard let minus = line.firstIndex(of: "-"),
      let plus = line[minus...].firstIndex(of: "+"),
      let old = integer(after: minus, in: line),
      let new = integer(after: plus, in: line)
    else { return nil }
    return (old, new)
  }

  private static func integer(after index: String.Index, in value: String) -> Int? {
    let suffix = value[value.index(after: index)...]
    return Int(suffix.prefix(while: \Character.isNumber))
  }
}
