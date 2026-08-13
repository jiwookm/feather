import Foundation

public enum GitWorktreeParser {
  public static func parse(_ data: Data) throws -> [GitWorktree] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: false)
    var result: [GitWorktree] = []
    var current: Builder?

    func finish(_ builder: Builder?) {
      guard let builder, let path = builder.path else { return }
      result.append(builder.build(path: path))
    }

    for rawField in fields {
      guard !rawField.isEmpty else {
        finish(current)
        current = nil
        continue
      }
      let field = String(decoding: rawField, as: UTF8.self)
      let pieces = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
      let key = String(pieces[0])
      let value = pieces.count == 2 ? String(pieces[1]) : nil

      if key == "worktree" {
        finish(current)
        current = Builder(path: value)
        continue
      }
      guard current != nil else { throw FeatherError.malformedGitOutput }
      switch key {
      case "HEAD": current?.head = value
      case "branch": current?.branch = value
      case "bare": current?.isBare = true
      case "detached": current?.isDetached = true
      case "locked": current?.isLocked = true
      case "prunable": current?.isPrunable = true
      default: break
      }
    }
    finish(current)
    return result
  }

  private struct Builder {
    var path: String?
    var head: String?
    var branch: String?
    var isBare = false
    var isDetached = false
    var isLocked = false
    var isPrunable = false

    func build(path: String) -> GitWorktree {
      GitWorktree(
        path: URL(fileURLWithPath: path).standardizedFileURL.path,
        head: head,
        branch: branch,
        isBare: isBare,
        isDetached: isDetached,
        isLocked: isLocked,
        isPrunable: isPrunable
      )
    }
  }
}

public actor GitService {
  private static let generatedWorktreeNames = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
    "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi",
    "chi", "psi", "omega",
  ]

  private let runner: CommandRunner
  private let gitExecutable: String

  public init(runner: CommandRunner = CommandRunner(), gitExecutable: String = "/usr/bin/git") {
    self.runner = runner
    self.gitExecutable = gitExecutable
  }

  public func inspectRepository(at selectedURL: URL) throws -> (RepositoryRecord, [GitWorktree]) {
    let selectedPath = selectedURL.standardizedFileURL.path
    let result = try runner.run(
      gitExecutable,
      arguments: ["-C", selectedPath, "worktree", "list", "--porcelain", "-z"]
    )
    let worktrees = try GitWorktreeParser.parse(result.data)
    guard let main = worktrees.first else { throw FeatherError.noWorktrees(selectedPath) }
    let name = URL(fileURLWithPath: main.path).lastPathComponent
    let remoteURL = try originRemoteURL(repositoryPath: main.path)
    return (
      RepositoryRecord(path: main.path, displayName: name, remoteURL: remoteURL), worktrees
    )
  }

  public func listWorktrees(repositoryPath: String) throws -> [GitWorktree] {
    let result = try runner.run(
      gitExecutable,
      arguments: ["-C", repositoryPath, "worktree", "list", "--porcelain", "-z"]
    )
    return try GitWorktreeParser.parse(result.data)
  }

  private func originRemoteURL(repositoryPath: String) throws -> String? {
    let result = try runner.run(
      gitExecutable,
      arguments: ["-C", repositoryPath, "remote", "get-url", "origin"],
      allowFailure: true
    )
    guard result.status == 0 else { return nil }
    let value = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// Refreshes remote-tracking refs without modifying the user's main checkout.
  /// A repository without an origin remains a valid local-only project.
  private func fetchOriginIfAvailable(repositoryPath: String) throws {
    guard try originRemoteURL(repositoryPath: repositoryPath) != nil else { return }
    try runner.run(
      gitExecutable,
      arguments: ["-C", repositoryPath, "fetch", "--prune", "origin"],
      environment: ["GIT_TERMINAL_PROMPT": "0"]
    )
  }

  public func defaultBase(repositoryPath: String) throws -> String {
    let originHead = try runner.run(
      gitExecutable,
      arguments: ["-C", repositoryPath, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
      allowFailure: true
    )
    if originHead.status == 0 {
      let value = originHead.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }

    for reference in [
      "refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main",
      "refs/heads/master",
    ] {
      let exists = try runner.run(
        gitExecutable,
        arguments: ["-C", repositoryPath, "show-ref", "--verify", "--quiet", reference],
        allowFailure: true
      )
      if exists.status == 0 {
        return
          reference
          .replacingOccurrences(of: "refs/remotes/", with: "")
          .replacingOccurrences(of: "refs/heads/", with: "")
      }
    }

    let current = try runner.run(
      gitExecutable,
      arguments: ["-C", repositoryPath, "symbolic-ref", "--quiet", "--short", "HEAD"],
      allowFailure: true
    )
    let branch = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return current.status == 0 && !branch.isEmpty ? branch : "HEAD"
  }

  public func acquireWorktree(
    repositoryPath: String,
    worktreesRoot: URL,
    reusablePaths: [String]
  ) throws -> GitWorktree {
    try prepareWorktreesRoot(worktreesRoot)
    try fetchOriginIfAvailable(repositoryPath: repositoryPath)
    let resolvedBase = try defaultBase(repositoryPath: repositoryPath)
    let linkedPaths = Set(try listWorktrees(repositoryPath: repositoryPath).map(\.path))

    for path in reusablePaths where linkedPaths.contains(normalized(path)) {
      do {
        return try resetForReuse(
          repositoryPath: repositoryPath,
          worktreePath: path,
          base: resolvedBase
        )
      } catch FeatherError.dirtyWorktree(_), FeatherError.worktreeNotMerged(_) {
        continue
      }
    }

    return try createWorktree(
      repositoryPath: repositoryPath,
      worktreesRoot: worktreesRoot,
      base: resolvedBase
    )
  }

  public func prepareWorktreesRoot(_ worktreesRoot: URL) throws {
    try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
    let marker = worktreesRoot.appendingPathComponent(".metadata_never_index")
    if !FileManager.default.fileExists(atPath: marker.path) {
      try Data().write(to: marker, options: .atomic)
    }
  }

  public func prepareWorktreeForReuse(
    repositoryPath: String,
    worktreePath: String
  ) throws -> GitWorktree {
    try fetchOriginIfAvailable(repositoryPath: repositoryPath)
    let normalizedPath = normalized(worktreePath)
    let linkedPaths = Set(try listWorktrees(repositoryPath: repositoryPath).map(\.path))
    guard linkedPaths.contains(normalizedPath) else {
      throw FeatherError.noWorktrees(normalizedPath)
    }
    return try resetForReuse(
      repositoryPath: repositoryPath,
      worktreePath: normalizedPath,
      base: try defaultBase(repositoryPath: repositoryPath)
    )
  }

  private func createWorktree(
    repositoryPath: String,
    worktreesRoot: URL,
    base: String
  ) throws -> GitWorktree {
    let repositoryName = URL(fileURLWithPath: repositoryPath).lastPathComponent
    let (name, destination) = try nextWorktreeDestination(
      repositoryPath: repositoryPath,
      repositoryName: repositoryName,
      worktreesRoot: worktreesRoot
    )

    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try runner.run(
      gitExecutable,
      arguments: [
        "-C", repositoryPath, "worktree", "add", "-b", name, destination.path, base,
      ]
    )

    let worktrees = try listWorktrees(repositoryPath: repositoryPath)
    guard let created = worktrees.first(where: { $0.path == destination.standardizedFileURL.path })
    else {
      throw FeatherError.noWorktrees(destination.path)
    }
    warmNodeDependenciesIfSafe(
      repositoryPath: repositoryPath,
      worktreePath: created.path
    )
    return created
  }

  /// APFS clone copies are independent inodes whose file data remains
  /// copy-on-write. This preserves isolation while avoiding a second package
  /// install when the exact dependency lock is already present in the main
  /// checkout. Any uncertainty is a skip, never a large ordinary copy.
  private func warmNodeDependenciesIfSafe(
    repositoryPath: String,
    worktreePath: String
  ) {
    let fileManager = FileManager.default
    let sourceRoot = URL(fileURLWithPath: repositoryPath, isDirectory: true)
    let destinationRoot = URL(fileURLWithPath: worktreePath, isDirectory: true)
    let source = sourceRoot.appendingPathComponent("node_modules", isDirectory: true)
    let destination = destinationRoot.appendingPathComponent("node_modules", isDirectory: true)

    guard fileManager.fileExists(atPath: source.path),
      !fileManager.fileExists(atPath: destination.path),
      (try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory
        == true,
      (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
      dependencyLocksMatch(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
    else { return }

    let ignored = try? runner.run(
      gitExecutable,
      arguments: [
        "-C", worktreePath, "check-ignore", "--quiet", "--no-index", "--", "node_modules/",
      ],
      allowFailure: true
    )
    guard ignored?.status == 0 else { return }

    let clone = try? runner.run(
      "/bin/cp",
      arguments: ["-R", "-c", source.path, destination.path],
      allowFailure: true
    )
    guard clone?.status != 0 else { return }
    // `cp -c` never falls back to a full copy. Remove only its exact,
    // just-created ignored destination if the clone could not complete.
    try? fileManager.removeItem(at: destination)
  }

  private func dependencyLocksMatch(sourceRoot: URL, destinationRoot: URL) -> Bool {
    let candidates = [
      "pnpm-lock.yaml", "yarn.lock", "package-lock.json", "npm-shrinkwrap.json", "bun.lock",
      "bun.lockb",
    ]
    let fileManager = FileManager.default
    var foundLock = false
    for name in candidates {
      let source = sourceRoot.appendingPathComponent(name)
      let destination = destinationRoot.appendingPathComponent(name)
      let sourceExists = fileManager.fileExists(atPath: source.path)
      let destinationExists = fileManager.fileExists(atPath: destination.path)
      guard sourceExists == destinationExists else { return false }
      if sourceExists {
        foundLock = true
        guard fileManager.contentsEqual(atPath: source.path, andPath: destination.path) else {
          return false
        }
      }
    }
    return foundLock
  }

  private func resetForReuse(
    repositoryPath: String,
    worktreePath: String,
    base: String
  ) throws -> GitWorktree {
    let normalizedPath = normalized(worktreePath)
    guard try isClean(worktreePath: normalizedPath) else {
      throw FeatherError.dirtyWorktree(normalizedPath)
    }

    let head = try runner.run(
      gitExecutable,
      arguments: ["-C", normalizedPath, "rev-parse", "HEAD"]
    ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let merged = try runner.run(
      gitExecutable,
      arguments: ["-C", repositoryPath, "merge-base", "--is-ancestor", head, base],
      allowFailure: true
    )
    guard merged.status == 0 else {
      throw FeatherError.worktreeNotMerged(normalizedPath)
    }

    // `reset --hard` updates tracked files but deliberately preserves ignored dependency and
    // build-cache directories. Untracked files cannot reach this point because of isClean().
    try runner.run(
      gitExecutable,
      arguments: ["-C", normalizedPath, "reset", "--hard", base]
    )
    let worktrees = try listWorktrees(repositoryPath: repositoryPath)
    guard let reused = worktrees.first(where: { $0.path == normalizedPath }) else {
      throw FeatherError.noWorktrees(normalizedPath)
    }
    return reused
  }

  public func isClean(worktreePath: String) throws -> Bool {
    let result = try runner.run(
      gitExecutable,
      arguments: ["-C", worktreePath, "status", "--porcelain=v1", "-z", "--untracked-files=all"]
    )
    return result.data.isEmpty
  }

  public func removeWorktree(repositoryPath: String, worktreePath: String) throws {
    let normalizedRepository = normalized(repositoryPath)
    let normalizedWorktree = normalized(worktreePath)
    guard normalizedRepository != normalizedWorktree else {
      throw FeatherError.mainWorktreeRemoval
    }
    guard try isClean(worktreePath: normalizedWorktree) else {
      throw FeatherError.dirtyWorktree(normalizedWorktree)
    }
    try runner.run(
      gitExecutable,
      arguments: ["-C", normalizedRepository, "worktree", "remove", normalizedWorktree]
    )
  }

  private func sanitizePathComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let transformed = value.unicodeScalars.map {
      allowed.contains($0) ? Character(String($0)) : "-"
    }
    let result = String(transformed)
    return result.isEmpty ? "worktree" : result
  }

  private func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func nextWorktreeDestination(
    repositoryPath: String,
    repositoryName: String,
    worktreesRoot: URL
  ) throws -> (String, URL) {
    let branches = try runner.run(
      gitExecutable,
      arguments: ["-C", repositoryPath, "for-each-ref", "--format=%(refname:short)", "refs/heads"]
    )
    let existingBranches = Set(branches.text.split(whereSeparator: \.isNewline).map(String.init))
    let repositoryRoot = worktreesRoot.appendingPathComponent(
      sanitizePathComponent(repositoryName), isDirectory: true)

    var index = 0
    while true {
      let stem = Self.generatedWorktreeNames[index % Self.generatedWorktreeNames.count]
      let generation = index / Self.generatedWorktreeNames.count
      let name = generation == 0 ? stem : "\(stem)-\(generation + 1)"
      let destination = repositoryRoot.appendingPathComponent(name, isDirectory: true)
      if !existingBranches.contains(name)
        && !FileManager.default.fileExists(atPath: destination.path)
      {
        return (name, destination)
      }
      index += 1
    }
  }
}
