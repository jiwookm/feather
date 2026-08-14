import CryptoKit
import Foundation

public struct RemoteHandoffLimits: Equatable, Sendable {
  public static let standard = RemoteHandoffLimits()

  public let maximumTransferBytes: Int
  public let maximumPatchBytes: Int
  public let maximumMetadataBytes: Int
  public let maximumUntrackedFiles: Int
  public let maximumUntrackedFileBytes: Int64
  public let maximumUntrackedBytes: Int64
  public let maximumUnpublishedObjectBytes: Int64

  public init(
    maximumTransferBytes: Int = 128 * 1_024 * 1_024,
    maximumPatchBytes: Int = 64 * 1_024 * 1_024,
    maximumMetadataBytes: Int = 8 * 1_024 * 1_024,
    maximumUntrackedFiles: Int = 10_000,
    maximumUntrackedFileBytes: Int64 = 64 * 1_024 * 1_024,
    maximumUntrackedBytes: Int64 = 96 * 1_024 * 1_024,
    maximumUnpublishedObjectBytes: Int64 = 96 * 1_024 * 1_024
  ) {
    self.maximumTransferBytes = maximumTransferBytes
    self.maximumPatchBytes = maximumPatchBytes
    self.maximumMetadataBytes = maximumMetadataBytes
    self.maximumUntrackedFiles = maximumUntrackedFiles
    self.maximumUntrackedFileBytes = maximumUntrackedFileBytes
    self.maximumUntrackedBytes = maximumUntrackedBytes
    self.maximumUnpublishedObjectBytes = maximumUnpublishedObjectBytes
  }
}

public enum RemoteTransferPathPolicy {
  public static func validate(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
      path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { throw RemoteHandoffError.unsupportedUntrackedPath(path) }

    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !components.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame })
    else { throw RemoteHandoffError.unsupportedUntrackedPath(path) }

    let lowered = components.map { $0.lowercased() }
    let protectedDirectories: Set<String> = [
      ".aws", ".azure", ".gnupg", ".kube", ".ssh",
    ]
    if lowered.contains(where: protectedDirectories.contains) {
      throw RemoteHandoffError.sensitiveUntrackedPath(path)
    }

    let name = lowered.last ?? ""
    let safeEnvironmentSuffixes = [".example", ".sample", ".template"]
    if (name == ".env" || name.hasPrefix(".env."))
      && !safeEnvironmentSuffixes.contains(where: name.hasSuffix)
    {
      throw RemoteHandoffError.sensitiveUntrackedPath(path)
    }

    let protectedNames: Set<String> = [
      ".netrc", ".npmrc", ".pypirc", "credentials", "credentials.json", "id_dsa",
      "id_ecdsa", "id_ed25519", "id_rsa", "secrets.json", "service-account.json",
    ]
    let protectedExtensions: Set<String> = ["key", "p12", "pem", "pfx"]
    if protectedNames.contains(name)
      || protectedExtensions.contains((name as NSString).pathExtension.lowercased())
    {
      throw RemoteHandoffError.sensitiveUntrackedPath(path)
    }
  }
}

struct RemoteGitStateTransferPayload: Sendable {
  let origin: String
  let preflight: RemoteHandoffPreflight
  let manifest: RemoteHandoffManifest
  let manifestSHA256: String
  let archive: Data
  let archiveSHA256: String
}

private struct CapturedUntrackedEntry: Sendable {
  enum Kind: String, Sendable {
    case file = "f"
    case symbolicLink = "l"
  }

  let path: String
  let kind: Kind
  let executable: Bool
  let byteCount: Int64
  let sha256: String

  var verificationLine: String {
    let encodedPath = Data(path.utf8).base64EncodedString()
    return [
      kind.rawValue,
      executable ? "1" : "0",
      String(byteCount),
      sha256,
      encodedPath,
    ].joined(separator: "\t") + "\n"
  }
}

private struct CapturedRemoteGitState: Sendable {
  let origin: String
  let fingerprint: RemoteHandoffStateFingerprint
  let status: Data
  let indexPatch: Data
  let worktreePatch: Data
  let untrackedPaths: Data
  let untrackedEntries: Data
}

actor RemoteGitStateTransfer {
  private let runner: BoundedCommandRunner
  private let gitExecutable: String
  private let tarExecutable: String
  private let limits: RemoteHandoffLimits
  private let fileManager: FileManager

  init(
    runner: BoundedCommandRunner,
    gitExecutable: String,
    tarExecutable: String = "/usr/bin/tar",
    limits: RemoteHandoffLimits = .standard,
    fileManager: FileManager = .default
  ) {
    self.runner = runner
    self.gitExecutable = gitExecutable
    self.tarExecutable = tarExecutable
    self.limits = limits
    self.fileManager = fileManager
  }

  func buildPayload(worktreePath: String) async throws -> RemoteGitStateTransferPayload {
    let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "Feather Remote Transfer \(UUID().uuidString)",
      isDirectory: true
    )
    let payloadRoot = temporaryRoot.appendingPathComponent("payload", isDirectory: true)
    let untrackedRoot = payloadRoot.appendingPathComponent("untracked", isDirectory: true)
    try fileManager.createDirectory(at: untrackedRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let capture = try await captureState(
      worktreePath: worktreePath,
      untrackedCopyRoot: untrackedRoot
    )
    try capture.status.write(to: payloadRoot.appendingPathComponent("status.snapshot"))
    try capture.indexPatch.write(to: payloadRoot.appendingPathComponent("index.patch"))
    try capture.worktreePatch.write(to: payloadRoot.appendingPathComponent("worktree.patch"))
    try capture.untrackedPaths.write(to: payloadRoot.appendingPathComponent("untracked.paths"))
    try capture.untrackedEntries.write(
      to: payloadRoot.appendingPathComponent("untracked.entries")
    )

    let bundleURL = payloadRoot.appendingPathComponent("commits.bundle")
    let bundleSHA256: String?
    if capture.fingerprint.unpublishedCommitCount > 0 {
      try await createBundle(
        at: bundleURL,
        worktreePath: worktreePath,
        baseCommit: capture.fingerprint.baseCommit,
        headCommit: capture.fingerprint.headCommit
      )
      bundleSHA256 = try Self.sha256File(bundleURL).hash
    } else {
      bundleSHA256 = nil
    }

    let artifactBytes = try Self.directoryByteCount(payloadRoot, fileManager: fileManager)
    let manifest = RemoteHandoffManifest(
      state: capture.fingerprint,
      bundleSHA256: bundleSHA256,
      artifactBytes: artifactBytes
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let manifestData = try encoder.encode(manifest)
    try manifestData.write(to: payloadRoot.appendingPathComponent("manifest.json"))

    var artifactNames = [
      "manifest.json", "status.snapshot", "index.patch", "worktree.patch",
      "untracked.paths", "untracked.entries", "untracked",
    ]
    if bundleSHA256 != nil { artifactNames.append("commits.bundle") }
    let archiveOutput = try await runner.run(
      tarExecutable,
      arguments: ["-C", payloadRoot.path, "-cf", "-"] + artifactNames,
      maximumOutputBytes: limits.maximumTransferBytes,
      timeout: 60
    )
    guard archiveOutput.status == 0 else {
      throw BoundedCommandFailure(
        executable: tarExecutable,
        arguments: ["create remote handoff payload"],
        status: archiveOutput.status,
        stderr: archiveOutput.stderrText
      )
    }
    let archive = archiveOutput.stdout
    guard archive.count <= limits.maximumTransferBytes else {
      throw RemoteHandoffError.transferTooLarge(limits.maximumTransferBytes)
    }
    return RemoteGitStateTransferPayload(
      origin: capture.origin,
      preflight: RemoteHandoffPreflight(
        state: capture.fingerprint,
        transferBytes: Int64(archive.count)
      ),
      manifest: manifest,
      manifestSHA256: Self.sha256(manifestData),
      archive: archive,
      archiveSHA256: Self.sha256(archive)
    )
  }

  func captureFingerprint(worktreePath: String) async throws -> RemoteHandoffStateFingerprint {
    try await captureState(worktreePath: worktreePath, untrackedCopyRoot: nil).fingerprint
  }

  private func captureState(
    worktreePath: String,
    untrackedCopyRoot: URL?
  ) async throws -> CapturedRemoteGitState {
    let branchOutput = try await git(
      ["-C", worktreePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
      allowFailure: true
    )
    let branch = branchOutput.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard branchOutput.status == 0, !branch.isEmpty else { throw RemoteHandoffError.detachedHead }

    let headCommit = try await gitText([
      "-C", worktreePath, "rev-parse", "--verify", "HEAD^{commit}",
    ])
    let originOutput = try await git(
      ["-C", worktreePath, "remote", "get-url", "origin"],
      allowFailure: true
    )
    let origin = originOutput.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard originOutput.status == 0, !origin.isEmpty else { throw RemoteHandoffError.missingOrigin }
    try Self.validateOrigin(origin)

    let remoteBranch = try await remoteCommit(
      worktreePath: worktreePath,
      reference: "refs/heads/\(branch)"
    )
    let baseCommit = try await resolveBaseCommit(
      worktreePath: worktreePath,
      headCommit: headCommit,
      publishedCommit: remoteBranch
    )
    let unpublishedCommitCount = try await revisionCount(
      worktreePath: worktreePath,
      range: "\(baseCommit)..\(headCommit)"
    )
    if unpublishedCommitCount > 0 {
      try await validateUnpublishedObjectSize(
        worktreePath: worktreePath,
        baseCommit: baseCommit,
        headCommit: headCommit
      )
    }

    async let statusOutput = git(
      [
        "-C", worktreePath, "status", "--porcelain=v1", "-z", "--untracked-files=all",
        "--no-renames",
      ],
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 20
    )
    async let indexPatchOutput = git(
      Self.diffArguments(worktreePath: worktreePath, cached: true),
      maximumOutputBytes: limits.maximumPatchBytes,
      timeout: 30
    )
    async let worktreePatchOutput = git(
      Self.diffArguments(worktreePath: worktreePath, cached: false),
      maximumOutputBytes: limits.maximumPatchBytes,
      timeout: 30
    )
    async let stagedPathsOutput = git(
      Self.nameOnlyArguments(worktreePath: worktreePath, cached: true),
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 20
    )
    async let unstagedPathsOutput = git(
      Self.nameOnlyArguments(worktreePath: worktreePath, cached: false),
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 20
    )
    async let untrackedPathsOutput = git(
      ["-C", worktreePath, "ls-files", "--others", "--exclude-standard", "-z"],
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 20
    )

    let status = try await statusOutput.stdout
    let indexPatch = try await indexPatchOutput.stdout
    let worktreePatch = try await worktreePatchOutput.stdout
    let stagedPaths = try Self.nulSeparatedPaths(try await stagedPathsOutput.stdout)
    let unstagedPaths = try Self.nulSeparatedPaths(try await unstagedPathsOutput.stdout)
    let untrackedPathsOutputValue = try await untrackedPathsOutput
    let untrackedPaths = try Self.nulSeparatedPaths(untrackedPathsOutputValue.stdout)
    guard untrackedPaths.count <= limits.maximumUntrackedFiles else {
      throw RemoteHandoffError.tooManyUntrackedFiles(limits.maximumUntrackedFiles)
    }

    let limits = limits
    let entries = try await Task.detached(priority: .utility) {
      try Self.captureUntrackedEntries(
        paths: untrackedPaths,
        worktreePath: worktreePath,
        copyRoot: untrackedCopyRoot,
        limits: limits,
        fileManager: .default
      )
    }.value
    let untrackedEntries = Data(entries.flatMap { $0.verificationLine.utf8 })
    let untrackedBytes = entries.reduce(Int64(0)) { $0 + $1.byteCount }

    return CapturedRemoteGitState(
      origin: origin,
      fingerprint: RemoteHandoffStateFingerprint(
        branch: branch,
        baseCommit: baseCommit,
        headCommit: headCommit,
        publishedCommit: remoteBranch,
        statusSHA256: Self.sha256(status),
        indexPatchSHA256: Self.sha256(indexPatch),
        worktreePatchSHA256: Self.sha256(worktreePatch),
        untrackedPathsSHA256: Self.sha256(untrackedPathsOutputValue.stdout),
        untrackedEntriesSHA256: Self.sha256(untrackedEntries),
        stagedPathCount: Set(stagedPaths).count,
        unstagedPathCount: Set(unstagedPaths).count,
        untrackedFileCount: entries.count,
        untrackedBytes: untrackedBytes,
        unpublishedCommitCount: unpublishedCommitCount
      ),
      status: status,
      indexPatch: indexPatch,
      worktreePatch: worktreePatch,
      untrackedPaths: untrackedPathsOutputValue.stdout,
      untrackedEntries: untrackedEntries
    )
  }

  private func resolveBaseCommit(
    worktreePath: String,
    headCommit: String,
    publishedCommit: String?
  ) async throws -> String {
    if let publishedCommit {
      guard try await commitExists(worktreePath: worktreePath, commit: publishedCommit) else {
        throw RemoteHandoffError.originFetchRequired
      }
      let ancestor = try await git(
        ["-C", worktreePath, "merge-base", "--is-ancestor", publishedCommit, headCommit],
        allowFailure: true
      )
      guard ancestor.status == 0 else { throw RemoteHandoffError.remoteBranchDiverged }
      return publishedCommit
    }

    var candidates: [String] = []
    if let remoteHead = try await remoteCommit(worktreePath: worktreePath, reference: "HEAD"),
      try await commitExists(worktreePath: worktreePath, commit: remoteHead)
    {
      candidates.append(remoteHead)
    }
    for reference in [
      "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master",
    ] {
      let output = try await git(
        ["-C", worktreePath, "rev-parse", "--verify", "\(reference)^{commit}"],
        allowFailure: true
      )
      if output.status == 0 {
        candidates.append(output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }

    for candidate in candidates where Self.isObjectID(candidate) {
      let mergeBase = try await git(
        ["-C", worktreePath, "merge-base", headCommit, candidate],
        allowFailure: true
      )
      let value = mergeBase.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      if mergeBase.status == 0, Self.isObjectID(value) { return value }
    }
    throw RemoteHandoffError.originFetchRequired
  }

  private func remoteCommit(worktreePath: String, reference: String) async throws -> String? {
    let output = try await git(
      ["-C", worktreePath, "ls-remote", "--exit-code", "origin", reference],
      allowFailure: true,
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 30
    )
    if output.status == 2 { return nil }
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: ["-C", worktreePath, "ls-remote", "origin", reference],
        status: output.status,
        stderr: output.stderrText
      )
    }
    let value = output.stdoutText.split(whereSeparator: \.isWhitespace).first.map(String.init)
    guard let value, Self.isObjectID(value) else { throw RemoteHandoffError.invalidGitState }
    return value
  }

  private func commitExists(worktreePath: String, commit: String) async throws -> Bool {
    let output = try await git(
      ["-C", worktreePath, "cat-file", "-e", "\(commit)^{commit}"],
      allowFailure: true
    )
    return output.status == 0
  }

  private func revisionCount(worktreePath: String, range: String) async throws -> Int {
    let value = try await gitText(["-C", worktreePath, "rev-list", "--count", range])
    guard let count = Int(value), count >= 0 else { throw RemoteHandoffError.invalidGitState }
    return count
  }

  private func validateUnpublishedObjectSize(
    worktreePath: String,
    baseCommit: String,
    headCommit: String
  ) async throws {
    let objects = try await git(
      ["-C", worktreePath, "rev-list", "--objects", "\(baseCommit)..\(headCommit)"],
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 30
    )
    let objectIDs = Set(
      objects.stdoutText.split(whereSeparator: \.isNewline).compactMap { line -> String? in
        let value = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return Self.isObjectID(value) ? value : nil
      }
    ).sorted()
    let input = Data((objectIDs.joined(separator: "\n") + "\n").utf8)
    let sizes = try await runner.run(
      gitExecutable,
      arguments: [
        "-C", worktreePath, "cat-file", "--batch-check=%(objectsize)",
      ],
      environment: Self.gitEnvironment,
      standardInput: input,
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 30
    )
    guard sizes.status == 0 else {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: ["cat-file", "--batch-check"],
        status: sizes.status,
        stderr: sizes.stderrText
      )
    }
    let total = try sizes.stdoutText.split(whereSeparator: \.isNewline).reduce(Int64(0)) {
      partial, value in
      guard let size = Int64(value), size >= 0 else { throw RemoteHandoffError.invalidGitState }
      let (sum, overflow) = partial.addingReportingOverflow(size)
      guard !overflow else {
        throw RemoteHandoffError.transferTooLarge(limits.maximumTransferBytes)
      }
      return sum
    }
    guard total <= limits.maximumUnpublishedObjectBytes else {
      throw RemoteHandoffError.unpublishedObjectsTooLarge(limits.maximumUnpublishedObjectBytes)
    }
  }

  private func createBundle(
    at url: URL,
    worktreePath: String,
    baseCommit: String,
    headCommit: String
  ) async throws {
    guard
      try await gitText(["-C", worktreePath, "rev-parse", "--verify", "HEAD^{commit}"])
        == headCommit
    else { throw RemoteHandoffError.checkpointChanged(worktreePath) }
    let output = try await git(
      ["-C", worktreePath, "bundle", "create", url.path, "HEAD", "^\(baseCommit)"],
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 60
    )
    guard output.status == 0, fileManager.fileExists(atPath: url.path) else {
      throw RemoteHandoffError.invalidGitState
    }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard size <= Int64(limits.maximumTransferBytes) else {
      throw RemoteHandoffError.transferTooLarge(limits.maximumTransferBytes)
    }
    let bundledHeads = try await git(
      ["-C", worktreePath, "bundle", "list-heads", url.path],
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 30
    )
    let containsCapturedHead = bundledHeads.stdoutText.split(whereSeparator: \.isNewline)
      .contains { line in
        line.split(whereSeparator: \.isWhitespace).first.map(String.init) == headCommit
      }
    guard containsCapturedHead,
      try await gitText(["-C", worktreePath, "rev-parse", "--verify", "HEAD^{commit}"])
        == headCommit
    else { throw RemoteHandoffError.checkpointChanged(worktreePath) }
  }

  private func gitText(_ arguments: [String]) async throws -> String {
    try await git(arguments).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func git(
    _ arguments: [String],
    allowFailure: Bool = false,
    maximumOutputBytes: Int? = nil,
    timeout: TimeInterval = 15
  ) async throws -> BoundedCommandOutput {
    let output = try await runner.run(
      gitExecutable,
      arguments: arguments,
      environment: Self.gitEnvironment,
      maximumOutputBytes: maximumOutputBytes ?? limits.maximumMetadataBytes,
      timeout: timeout
    )
    if !allowFailure, output.status != 0 {
      throw BoundedCommandFailure(
        executable: gitExecutable,
        arguments: arguments,
        status: output.status,
        stderr: output.stderrText
      )
    }
    return output
  }

  private static func captureUntrackedEntries(
    paths: [String],
    worktreePath: String,
    copyRoot: URL?,
    limits: RemoteHandoffLimits,
    fileManager: FileManager
  ) throws -> [CapturedUntrackedEntry] {
    var entries: [CapturedUntrackedEntry] = []
    var totalBytes: Int64 = 0
    let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)

    for path in paths {
      try RemoteTransferPathPolicy.validate(path)
      var ancestor = worktreeURL
      for component in path.split(separator: "/").dropLast() {
        ancestor.appendPathComponent(String(component), isDirectory: true)
        let ancestorAttributes = try fileManager.attributesOfItem(atPath: ancestor.path)
        guard ancestorAttributes[.type] as? FileAttributeType != .typeSymbolicLink else {
          throw RemoteHandoffError.unsupportedUntrackedPath(path)
        }
      }
      let source = worktreeURL.appendingPathComponent(path)
      let attributes = try fileManager.attributesOfItem(atPath: source.path)
      let type = attributes[.type] as? FileAttributeType
      if type == .typeRegular {
        let sourceBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceBytes >= 0, sourceBytes <= limits.maximumUntrackedFileBytes else {
          throw RemoteHandoffError.untrackedFileTooLarge(
            path,
            limits.maximumUntrackedFileBytes
          )
        }
        let (prospectiveTotal, overflow) = totalBytes.addingReportingOverflow(sourceBytes)
        guard !overflow, prospectiveTotal <= limits.maximumUntrackedBytes else {
          throw RemoteHandoffError.untrackedFilesTooLarge(limits.maximumUntrackedBytes)
        }
      }
      let captureURL: URL
      if let copyRoot {
        let destination = copyRoot.appendingPathComponent(path)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        if type == .typeSymbolicLink {
          let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
          guard
            target.unicodeScalars.allSatisfy({
              !CharacterSet.controlCharacters.contains($0)
            })
          else { throw RemoteHandoffError.unsupportedUntrackedPath(path) }
          try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        } else if type == .typeRegular {
          try fileManager.copyItem(at: source, to: destination)
        } else {
          throw RemoteHandoffError.unsupportedUntrackedFile(path)
        }
        captureURL = destination
      } else {
        captureURL = source
      }

      let capturedAttributes = try fileManager.attributesOfItem(atPath: captureURL.path)
      let capturedType = capturedAttributes[.type] as? FileAttributeType
      let permissions = (capturedAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
      let executable = permissions & 0o111 != 0
      let entry: CapturedUntrackedEntry
      if capturedType == .typeSymbolicLink {
        let target = try fileManager.destinationOfSymbolicLink(atPath: captureURL.path)
        guard
          target.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
          })
        else { throw RemoteHandoffError.unsupportedUntrackedPath(path) }
        let data = Data(target.utf8)
        entry = CapturedUntrackedEntry(
          path: path,
          kind: .symbolicLink,
          executable: false,
          byteCount: Int64(data.count),
          sha256: sha256(data)
        )
      } else if capturedType == .typeRegular {
        let result = try sha256File(captureURL)
        guard result.byteCount <= limits.maximumUntrackedFileBytes else {
          throw RemoteHandoffError.untrackedFileTooLarge(
            path,
            limits.maximumUntrackedFileBytes
          )
        }
        entry = CapturedUntrackedEntry(
          path: path,
          kind: .file,
          executable: executable,
          byteCount: result.byteCount,
          sha256: result.hash
        )
      } else {
        throw RemoteHandoffError.unsupportedUntrackedFile(path)
      }
      let (newTotal, overflow) = totalBytes.addingReportingOverflow(entry.byteCount)
      guard !overflow, newTotal <= limits.maximumUntrackedBytes else {
        throw RemoteHandoffError.untrackedFilesTooLarge(limits.maximumUntrackedBytes)
      }
      totalBytes = newTotal
      entries.append(entry)
    }
    return entries
  }

  private static func nulSeparatedPaths(_ data: Data) throws -> [String] {
    try data.split(separator: 0).map { bytes in
      guard let value = String(data: Data(bytes), encoding: .utf8) else {
        throw RemoteHandoffError.unsupportedUntrackedPath("non-UTF-8 path")
      }
      return value
    }
  }

  private static func diffArguments(worktreePath: String, cached: Bool) -> [String] {
    var arguments = [
      "-C", worktreePath,
      "-c", "diff.mnemonicPrefix=false",
      "-c", "diff.noprefix=false",
      "diff", "--binary", "--full-index", "--no-color", "--no-ext-diff", "--no-textconv",
      "--no-renames", "--src-prefix=a/", "--dst-prefix=b/",
    ]
    if cached { arguments.append("--cached") }
    return arguments
  }

  private static func nameOnlyArguments(worktreePath: String, cached: Bool) -> [String] {
    var arguments = [
      "-C", worktreePath, "diff", "--name-only", "--no-renames", "-z",
    ]
    if cached { arguments.append("--cached") }
    return arguments
  }

  private static func isObjectID(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64)
      && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      }
  }

  private static func validateOrigin(_ origin: String) throws {
    guard let components = URLComponents(string: origin), let scheme = components.scheme else {
      return
    }
    let webOrigin =
      scheme.caseInsensitiveCompare("http") == .orderedSame
      || scheme.caseInsensitiveCompare("https") == .orderedSame
    guard components.password == nil, components.query == nil, components.fragment == nil,
      !webOrigin || components.user == nil
    else { throw RemoteHandoffError.credentialBearingOrigin }
  }

  private static func directoryByteCount(_ url: URL, fileManager: FileManager) throws -> Int64 {
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
      )
    else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { continue }
      let (sum, overflow) = total.addingReportingOverflow(Int64(values.fileSize ?? 0))
      guard !overflow else { throw RemoteHandoffError.transferTooLarge(Int.max) }
      total = sum
    }
    return total
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256File(_ url: URL) throws -> (hash: String, byteCount: Int64) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while true {
      let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
      byteCount += Int64(data.count)
    }
    return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteCount)
  }

  private static let gitEnvironment = [
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
  ]
}
