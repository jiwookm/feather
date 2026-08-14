import CryptoKit
import Foundation

public struct RemoteReturnPreflight: Equatable, Sendable {
  public let state: RemoteHandoffStateFingerprint
  public let transferBytes: Int64
  public let activeSessionCount: Int

  public init(
    state: RemoteHandoffStateFingerprint,
    transferBytes: Int64,
    activeSessionCount: Int
  ) {
    self.state = state
    self.transferBytes = transferBytes
    self.activeSessionCount = activeSessionCount
  }
}

public struct RemoteReturnPreparation: Sendable {
  public let preflight: RemoteReturnPreflight
  public let recordedSessionIDs: [String]
  fileprivate let workspaceID: UUID
  fileprivate let payload: RemoteGitStateTransferPayload
  fileprivate let untrackedArchiveSHA256: String
  fileprivate let untrackedPaths: Data

  fileprivate init(
    workspaceID: UUID,
    payload: RemoteGitStateTransferPayload,
    untrackedArchiveSHA256: String,
    untrackedPaths: Data,
    recordedSessionIDs: [String],
    activeSessionCount: Int
  ) {
    self.workspaceID = workspaceID
    self.payload = payload
    self.untrackedArchiveSHA256 = untrackedArchiveSHA256
    self.untrackedPaths = untrackedPaths
    self.recordedSessionIDs = recordedSessionIDs
    preflight = RemoteReturnPreflight(
      state: payload.manifest.state,
      transferBytes: payload.preflight.transferBytes,
      activeSessionCount: activeSessionCount
    )
  }
}

public struct RemoteCleanupPreflight: Equatable, Sendable {
  public let activeSessionCount: Int

  public init(activeSessionCount: Int) {
    self.activeSessionCount = activeSessionCount
  }
}

private struct RemotePathCheckpoint: Equatable, Sendable {
  let branch: String
  let headCommit: String
  let untrackedPaths: Data
}

private struct RemotePayloadCapture: Sendable {
  let payload: RemoteGitStateTransferPayload
  let untrackedArchiveSHA256: String
}

public actor RemoteReturnService {
  private let runner: BoundedCommandRunner
  private let sshExecutable: String
  private let gitExecutable: String
  private let tarExecutable: String
  private let limits: RemoteHandoffLimits
  private let fileManager: FileManager
  private let stateTransfer: RemoteGitStateTransfer

  public init(
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    sshExecutable: String = "/usr/bin/ssh",
    gitExecutable: String = "/usr/bin/git",
    tarExecutable: String = "/usr/bin/tar",
    limits: RemoteHandoffLimits = .standard,
    fileManager: FileManager = .default
  ) {
    self.runner = runner
    self.sshExecutable = sshExecutable
    self.gitExecutable = gitExecutable
    self.tarExecutable = tarExecutable
    self.limits = limits
    self.fileManager = fileManager
    stateTransfer = RemoteGitStateTransfer(
      runner: runner,
      gitExecutable: gitExecutable,
      tarExecutable: tarExecutable,
      limits: limits
    )
  }

  public func prepareReturn(
    workspace: RemoteWorkspaceRecord,
    localWorktreePath: String,
    recordedSessionIDs: [String]
  ) async throws -> RemoteReturnPreparation {
    try RemoteWorkspaceOwnershipValidator.validate(workspace)
    guard workspace.isRemoteAuthoritative, let handoff = workspace.handoff,
      workspace.ownership != nil
    else { throw RemoteHandoffError.remoteReturnUnavailable }

    try await requireUnchangedLocalCheckpoint(at: localWorktreePath, expected: handoff.state)

    let pathCheckpoint = try await captureRemotePaths(workspace, baseState: handoff.state)
    let untrackedPaths = try RemoteGitStateTransfer.nulSeparatedPaths(
      pathCheckpoint.untrackedPaths
    )
    guard untrackedPaths.count <= limits.maximumUntrackedFiles else {
      throw RemoteHandoffError.tooManyUntrackedFiles(limits.maximumUntrackedFiles)
    }
    for path in untrackedPaths { try RemoteTransferPathPolicy.validate(path) }

    let capture = try await captureRemotePayload(
      workspace,
      baseState: handoff.state,
      pathCheckpoint: pathCheckpoint
    )
    let sessionIDs = try normalizedSessionIDs(recordedSessionIDs, workspace: workspace)
    let activeCount = try await activeSessionIDs(sessionIDs, workspace: workspace).count
    return RemoteReturnPreparation(
      workspaceID: workspace.id,
      payload: capture.payload,
      untrackedArchiveSHA256: capture.untrackedArchiveSHA256,
      untrackedPaths: pathCheckpoint.untrackedPaths,
      recordedSessionIDs: sessionIDs,
      activeSessionCount: activeCount
    )
  }

  public func returnWorkspace(
    _ workspace: RemoteWorkspaceRecord,
    to localWorktreePath: String,
    preparation: RemoteReturnPreparation
  ) async throws -> RemoteWorkspaceReturnRecord {
    try RemoteWorkspaceOwnershipValidator.validate(workspace)
    guard preparation.workspaceID == workspace.id, workspace.isRemoteAuthoritative,
      let handoff = workspace.handoff, workspace.ownership != nil
    else { throw RemoteHandoffError.remoteReturnUnavailable }

    try await requireUnchangedLocalCheckpoint(
      at: localWorktreePath,
      expected: handoff.state
    )
    let rollback = try await stateTransfer.buildPayload(
      worktreePath: localWorktreePath,
      relativeTo: handoff.state
    )
    guard rollback.manifest.state == handoff.state else {
      throw RemoteHandoffError.localReturnDiverged(localWorktreePath)
    }
    let rollbackUntrackedPaths = try await validatedPayloadPaths(rollback)
    let remoteUntrackedPaths = try RemoteGitStateTransfer.nulSeparatedPaths(
      preparation.untrackedPaths
    )
    let localIgnoredPaths = try await captureLocalIgnoredPaths(at: localWorktreePath)
    let replacementPaths = try await verifyPayloadInStaging(
      preparation.payload,
      localWorktreePath: localWorktreePath,
      originalState: handoff.state,
      preservingIgnoredPaths: localIgnoredPaths
    )
    try await rejectIgnoredLocalCollisions(
      replacementPaths,
      at: localWorktreePath
    )
    try await requireUnchangedLocalCheckpoint(
      at: localWorktreePath,
      expected: handoff.state
    )
    try await verifyRemotePayloadCurrent(workspace, preparation: preparation)

    var localMutationStarted = false
    do {
      try Task.checkCancellation()
      localMutationStarted = true
      try await applyPayload(
        preparation.payload,
        to: localWorktreePath,
        removingUntrackedPaths: rollbackUntrackedPaths
      )
      let applied = try await stateTransfer.captureFingerprint(
        worktreePath: localWorktreePath,
        relativeTo: handoff.state
      )
      guard applied == preparation.payload.manifest.state else {
        throw RemoteHandoffError.invalidGitState
      }

      try await endRecordedSessions(preparation.recordedSessionIDs, workspace: workspace)
      try await verifyRemotePayloadCurrent(workspace, preparation: preparation)
      return RemoteWorkspaceReturnRecord(
        manifest: preparation.payload.manifest,
        cleanupSessionIDs: preparation.recordedSessionIDs
      )
    } catch {
      if localMutationStarted {
        do {
          try await applyPayload(
            rollback,
            to: localWorktreePath,
            removingUntrackedPaths: remoteUntrackedPaths
          )
          let restored = try await stateTransfer.captureFingerprint(
            worktreePath: localWorktreePath,
            relativeTo: handoff.state
          )
          guard restored == handoff.state else {
            throw RemoteHandoffError.returnRecoveryFailed(localWorktreePath)
          }
        } catch {
          throw RemoteHandoffError.returnRecoveryFailed(localWorktreePath)
        }
      }
      if error is CancellationError { throw error }
      if error as? RemoteHandoffError == .remoteReturnChanged { throw error }
      throw error
    }
  }

  public func cleanupPreflight(
    workspace: RemoteWorkspaceRecord
  ) async throws -> RemoteCleanupPreflight {
    try RemoteWorkspaceOwnershipValidator.validate(workspace)
    guard let returned = workspace.returned, workspace.ownership != nil else {
      throw RemoteHandoffError.remoteCleanupRefused
    }
    try await verifyRemoteOwnership(workspace)
    return RemoteCleanupPreflight(
      activeSessionCount: try await activeSessionIDs(
        returned.cleanupSessionIDs,
        workspace: workspace
      ).count
    )
  }

  public func cleanupWorkspace(
    _ workspace: RemoteWorkspaceRecord,
    endingActiveSessions: Bool
  ) async throws {
    try RemoteWorkspaceOwnershipValidator.validate(workspace)
    guard let returned = workspace.returned, let ownership = workspace.ownership else {
      throw RemoteHandoffError.remoteCleanupRefused
    }
    let active = try await activeSessionIDs(returned.cleanupSessionIDs, workspace: workspace)
    guard active.isEmpty || endingActiveSessions else {
      throw RemoteHandoffError.activeRemoteSessions(active.count)
    }
    let token = UUID().uuidString.lowercased()
    let output = try await runSSH(
      workspace.remote.target,
      script: Self.cleanupScript(
        workspace: workspace,
        ownership: ownership,
        sessionIDs: returned.cleanupSessionIDs,
        endSessions: endingActiveSessions,
        receiptToken: token
      ),
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 60
    )
    guard output.status == 0,
      output.stdoutText.split(whereSeparator: \.isNewline).last.map(String.init)
        == "cleaned:\(token)"
    else {
      if output.status == 43 {
        let currentCount =
          (try? await activeSessionIDs(returned.cleanupSessionIDs, workspace: workspace).count)
          ?? active.count
        throw RemoteHandoffError.activeRemoteSessions(max(1, currentCount))
      }
      throw RemoteHandoffError.remoteCleanupRefused
    }
  }

  private func requireUnchangedLocalCheckpoint(
    at path: String,
    expected: RemoteHandoffStateFingerprint
  ) async throws {
    do {
      let state = try await stateTransfer.captureFingerprint(
        worktreePath: path,
        relativeTo: expected
      )
      guard state == expected else { throw RemoteHandoffError.localReturnDiverged(path) }
    } catch let error as RemoteHandoffError where error == .localReturnDiverged(path) {
      throw error
    } catch {
      throw RemoteHandoffError.localReturnDiverged(path)
    }
  }

  private func verifyPayloadInStaging(
    _ payload: RemoteGitStateTransferPayload,
    localWorktreePath: String,
    originalState: RemoteHandoffStateFingerprint,
    preservingIgnoredPaths: [String]
  ) async throws -> [String] {
    let root = try makeTemporaryDirectory(named: "Feather Return Verification")
    defer { try? fileManager.removeItem(at: root) }
    let payloadRoot = try await extractAndValidatePayload(payload, under: root)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try await requireGitSuccess([
      "clone", "--no-checkout", "--shared", "--", localWorktreePath, staging.path,
    ])
    try await importBundleIfNeeded(payload, payloadRoot: payloadRoot, repositoryPath: staging.path)
    try await requireGitSuccess([
      "-C", staging.path, "checkout", "-B", payload.manifest.state.branch,
      payload.manifest.state.headCommit,
    ])
    try await applyPatches(payloadRoot: payloadRoot, repositoryPath: staging.path)
    let paths = try payloadPaths(at: payloadRoot)
    try copyUntracked(
      from: payloadRoot.appendingPathComponent("untracked", isDirectory: true),
      to: URL(fileURLWithPath: staging.path, isDirectory: true),
      paths: paths
    )
    let state = try await stateTransfer.captureFingerprint(
      worktreePath: staging.path,
      relativeTo: payload.manifest.state
    )
    guard state == payload.manifest.state else { throw RemoteHandoffError.invalidGitState }
    try await requirePathsRemainIgnored(preservingIgnoredPaths, in: staging.path)
    let changedPaths = try RemoteGitStateTransfer.nulSeparatedPaths(
      try await gitOutput([
        "-C", staging.path, "diff", "--name-only", "--no-renames", "-z",
        originalState.headCommit,
      ]).stdout
    )
    return Array(Set(changedPaths + paths)).sorted()
  }

  private func applyPayload(
    _ payload: RemoteGitStateTransferPayload,
    to localWorktreePath: String,
    removingUntrackedPaths: [String]
  ) async throws {
    let root = try makeTemporaryDirectory(named: "Feather Return Application")
    defer { try? fileManager.removeItem(at: root) }
    let payloadRoot = try await extractAndValidatePayload(payload, under: root)
    let paths = try payloadPaths(at: payloadRoot)
    try await importBundleIfNeeded(
      payload,
      payloadRoot: payloadRoot,
      repositoryPath: localWorktreePath
    )
    try removeUntracked(
      removingUntrackedPaths,
      from: URL(fileURLWithPath: localWorktreePath)
    )
    try await requireGitSuccess([
      "-C", localWorktreePath, "reset", "--hard", payload.manifest.state.headCommit,
    ])
    try await applyPatches(payloadRoot: payloadRoot, repositoryPath: localWorktreePath)
    try copyUntracked(
      from: payloadRoot.appendingPathComponent("untracked", isDirectory: true),
      to: URL(fileURLWithPath: localWorktreePath, isDirectory: true),
      paths: paths
    )
  }

  private func extractAndValidatePayload(
    _ payload: RemoteGitStateTransferPayload,
    under root: URL
  ) async throws -> URL {
    guard RemoteGitStateTransfer.sha256(payload.archive) == payload.archiveSHA256,
      payload.archive.count <= limits.maximumTransferBytes
    else { throw RemoteHandoffError.invalidGitState }
    let payloadRoot = root.appendingPathComponent("payload", isDirectory: true)
    try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
    try await extractTopLevelArchive(payload.archive, to: payloadRoot)
    let manifestData = try boundedData(
      at: payloadRoot.appendingPathComponent("manifest.json"),
      maximumBytes: limits.maximumMetadataBytes
    )
    guard RemoteGitStateTransfer.sha256(manifestData) == payload.manifestSHA256,
      try JSONDecoder().decode(RemoteHandoffManifest.self, from: manifestData) == payload.manifest
    else { throw RemoteHandoffError.invalidGitState }
    let status = try boundedData(
      at: payloadRoot.appendingPathComponent("status.snapshot"),
      maximumBytes: limits.maximumMetadataBytes
    )
    let index = try boundedData(
      at: payloadRoot.appendingPathComponent("index.patch"),
      maximumBytes: limits.maximumPatchBytes
    )
    let worktree = try boundedData(
      at: payloadRoot.appendingPathComponent("worktree.patch"),
      maximumBytes: limits.maximumPatchBytes
    )
    let untrackedPaths = try boundedData(
      at: payloadRoot.appendingPathComponent("untracked.paths"),
      maximumBytes: limits.maximumMetadataBytes
    )
    let untrackedEntries = try boundedData(
      at: payloadRoot.appendingPathComponent("untracked.entries"),
      maximumBytes: limits.maximumMetadataBytes
    )
    let state = payload.manifest.state
    guard RemoteGitStateTransfer.sha256(status) == state.statusSHA256,
      RemoteGitStateTransfer.sha256(index) == state.indexPatchSHA256,
      RemoteGitStateTransfer.sha256(worktree) == state.worktreePatchSHA256,
      RemoteGitStateTransfer.sha256(untrackedPaths) == state.untrackedPathsSHA256,
      RemoteGitStateTransfer.sha256(untrackedEntries) == state.untrackedEntriesSHA256
    else { throw RemoteHandoffError.invalidGitState }
    let paths = try RemoteGitStateTransfer.nulSeparatedPaths(untrackedPaths)
    guard paths.count == state.untrackedFileCount else { throw RemoteHandoffError.invalidGitState }
    for path in paths { try RemoteTransferPathPolicy.validate(path) }
    let untrackedRoot = payloadRoot.appendingPathComponent("untracked", isDirectory: true)
    let entries = try RemoteGitStateTransfer.captureUntrackedEntries(
      paths: paths,
      worktreePath: untrackedRoot.path,
      copyRoot: nil,
      limits: limits,
      fileManager: fileManager
    )
    guard Data(entries.flatMap { $0.verificationLine.utf8 }) == untrackedEntries,
      entries.reduce(Int64(0), { $0 + $1.byteCount }) == state.untrackedBytes
    else { throw RemoteHandoffError.invalidGitState }
    try validateExtractedPaths(paths, at: untrackedRoot)
    return payloadRoot
  }

  private func payloadPaths(at payloadRoot: URL) throws -> [String] {
    try RemoteGitStateTransfer.nulSeparatedPaths(
      boundedData(
        at: payloadRoot.appendingPathComponent("untracked.paths"),
        maximumBytes: limits.maximumMetadataBytes
      )
    )
  }

  private func validatedPayloadPaths(
    _ payload: RemoteGitStateTransferPayload
  ) async throws -> [String] {
    let root = try makeTemporaryDirectory(named: "Feather Return Path Validation")
    defer { try? fileManager.removeItem(at: root) }
    return try payloadPaths(at: try await extractAndValidatePayload(payload, under: root))
  }

  private func captureLocalIgnoredPaths(at worktreePath: String) async throws -> [String] {
    let output = try await gitOutput([
      "-C", worktreePath, "ls-files", "--others", "--ignored", "--exclude-standard",
      "--directory", "--no-empty-directory", "-z",
    ])
    let paths = try RemoteGitStateTransfer.nulSeparatedPaths(output.stdout).map {
      try normalizedRelativeGitPath($0)
    }
    return Array(Set(paths)).sorted()
  }

  private func requirePathsRemainIgnored(
    _ paths: [String],
    in repositoryPath: String
  ) async throws {
    guard !paths.isEmpty else { return }
    let ignored = try await ignoredPaths(paths, in: repositoryPath)
    guard let exposed = paths.first(where: { !ignored.contains($0) }) else { return }
    throw RemoteHandoffError.localIgnoredPathConflict(exposed)
  }

  private func rejectIgnoredLocalCollisions(
    _ replacementPaths: [String],
    at worktreePath: String
  ) async throws {
    let root = URL(fileURLWithPath: worktreePath, isDirectory: true)
    var candidates: Set<String> = []
    for value in replacementPaths {
      let path = try normalizedRelativeGitPath(value)
      let components = path.split(separator: "/").map(String.init)
      var candidate = ""
      for (index, component) in components.enumerated() {
        candidate = candidate.isEmpty ? component : "\(candidate)/\(component)"
        let url = root.appendingPathComponent(candidate)
        guard itemExists(at: url) else { continue }
        let type =
          try fileManager.attributesOfItem(atPath: url.path)[.type]
          as? FileAttributeType
        if index == components.count - 1 || type != .typeDirectory {
          candidates.insert(candidate)
        }
        if type != .typeDirectory { break }
      }
    }
    guard !candidates.isEmpty else { return }
    let ignored = try await ignoredPaths(candidates.sorted(), in: worktreePath)
    guard let collision = candidates.sorted().first(where: ignored.contains) else { return }
    throw RemoteHandoffError.localIgnoredPathConflict(collision)
  }

  private func ignoredPaths(
    _ paths: [String],
    in repositoryPath: String
  ) async throws -> Set<String> {
    let input = Data(paths.flatMap { Array($0.utf8) + [0] })
    let output = try await runner.run(
      gitExecutable,
      arguments: [
        "-C", repositoryPath, "check-ignore", "--no-index", "-z", "--stdin",
      ],
      environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"],
      standardInput: input,
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 60
    )
    guard output.status == 0 || output.status == 1 else {
      throw Self.commandFailure(
        output,
        executable: gitExecutable,
        arguments: ["check ignored local return paths"]
      )
    }
    return try Set(
      RemoteGitStateTransfer.nulSeparatedPaths(output.stdout).map {
        try normalizedRelativeGitPath($0)
      }
    )
  }

  private func normalizedRelativeGitPath(_ value: String) throws -> String {
    let marksDirectory = value.hasSuffix("/")
    let path = marksDirectory ? String(value.dropLast()) : value
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
      path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !components.contains(where: {
        String($0).caseInsensitiveCompare(".git") == .orderedSame
      })
    else { throw RemoteHandoffError.invalidGitState }
    return marksDirectory ? path + "/" : path
  }

  private func importBundleIfNeeded(
    _ payload: RemoteGitStateTransferPayload,
    payloadRoot: URL,
    repositoryPath: String
  ) async throws {
    guard let expectedHash = payload.manifest.bundleSHA256 else {
      guard
        !fileManager.fileExists(
          atPath: payloadRoot.appendingPathComponent("commits.bundle").path
        )
      else { throw RemoteHandoffError.invalidGitState }
      return
    }
    let bundle = payloadRoot.appendingPathComponent("commits.bundle")
    let result = try RemoteGitStateTransfer.sha256File(bundle)
    guard result.hash == expectedHash, result.byteCount <= Int64(limits.maximumTransferBytes) else {
      throw RemoteHandoffError.invalidGitState
    }
    try await requireGitSuccess(["-C", repositoryPath, "bundle", "verify", bundle.path])
    try await requireGitSuccess(["-C", repositoryPath, "bundle", "unbundle", bundle.path])
  }

  private func applyPatches(payloadRoot: URL, repositoryPath: String) async throws {
    let index = payloadRoot.appendingPathComponent("index.patch")
    let worktree = payloadRoot.appendingPathComponent("worktree.patch")
    if (try fileManager.attributesOfItem(atPath: index.path)[.size] as? NSNumber)?.intValue != 0 {
      try await requireGitSuccess([
        "-C", repositoryPath, "apply", "--binary", "--index", "--whitespace=nowarn",
        index.path,
      ])
    }
    if (try fileManager.attributesOfItem(atPath: worktree.path)[.size] as? NSNumber)?.intValue != 0
    {
      try await requireGitSuccess([
        "-C", repositoryPath, "apply", "--binary", "--whitespace=nowarn", worktree.path,
      ])
    }
  }

  private func removeUntracked(_ paths: [String], from root: URL) throws {
    for path in paths {
      try RemoteTransferPathPolicy.validate(path)
      let target = root.appendingPathComponent(path)
      guard itemExists(at: target) else { continue }
      try validateAncestors(of: path, under: root)
      try fileManager.removeItem(at: target)
    }
  }

  private func copyUntracked(from sourceRoot: URL, to destinationRoot: URL, paths: [String]) throws
  {
    for path in paths {
      try RemoteTransferPathPolicy.validate(path)
      try validateAncestors(of: path, under: sourceRoot)
      try validateAncestors(of: path, under: destinationRoot, allowMissing: true)
      let source = sourceRoot.appendingPathComponent(path)
      let destination = destinationRoot.appendingPathComponent(path)
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard !itemExists(at: destination) else {
        throw RemoteHandoffError.invalidGitState
      }
      let type = try fileManager.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
      if type == .typeSymbolicLink {
        let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
      } else if type == .typeRegular {
        try fileManager.copyItem(at: source, to: destination)
      } else {
        throw RemoteHandoffError.unsupportedUntrackedFile(path)
      }
    }
  }

  private func validateAncestors(
    of path: String,
    under root: URL,
    allowMissing: Bool = false
  ) throws {
    var ancestor = root
    for component in path.split(separator: "/").dropLast() {
      ancestor.appendPathComponent(String(component), isDirectory: true)
      guard itemExists(at: ancestor) else {
        if allowMissing { continue }
        throw RemoteHandoffError.invalidGitState
      }
      let type =
        try fileManager.attributesOfItem(atPath: ancestor.path)[.type]
        as? FileAttributeType
      guard type != .typeSymbolicLink else {
        throw RemoteHandoffError.unsupportedUntrackedPath(path)
      }
    }
  }

  private func gitOutput(_ arguments: [String]) async throws -> BoundedCommandOutput {
    let output = try await runner.run(
      gitExecutable,
      arguments: arguments,
      environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"],
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 60
    )
    guard output.status == 0 else {
      throw Self.commandFailure(output, executable: gitExecutable, arguments: arguments)
    }
    return output
  }

  private func itemExists(at url: URL) -> Bool {
    (try? fileManager.attributesOfItem(atPath: url.path)) != nil
  }

  private func requireGitSuccess(_ arguments: [String]) async throws {
    _ = try await gitOutput(arguments)
  }

  private func verifyRemotePayloadCurrent(
    _ workspace: RemoteWorkspaceRecord,
    preparation: RemoteReturnPreparation
  ) async throws {
    let token = UUID().uuidString.lowercased()
    let output = try await runSSH(
      workspace.remote.target,
      script: Self.payloadVerificationScript(
        workspace: workspace,
        state: preparation.payload.manifest.state,
        untrackedArchiveSHA256: preparation.untrackedArchiveSHA256,
        token: token
      ),
      standardInput: preparation.untrackedPaths,
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 120
    )
    guard output.status == 0,
      output.stdoutText.split(whereSeparator: \.isNewline).last.map(String.init)
        == "current:\(token)"
    else {
      if output.status == 42 { throw RemoteHandoffError.remoteCleanupRefused }
      throw RemoteHandoffError.remoteReturnChanged
    }
  }

  private func endRecordedSessions(
    _ sessionIDs: [String],
    workspace: RemoteWorkspaceRecord
  ) async throws {
    let token = UUID().uuidString.lowercased()
    let output = try await runSSH(
      workspace.remote.target,
      script: Self.endSessionsScript(
        workspace: workspace,
        sessionIDs: sessionIDs,
        token: token
      ),
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 60
    )
    guard output.status == 0,
      output.stdoutText.split(whereSeparator: \.isNewline).last.map(String.init)
        == "ended:\(token)"
    else {
      if output.status == 42 { throw RemoteHandoffError.remoteCleanupRefused }
      throw Self.remoteFailure(
        output,
        executable: sshExecutable,
        operation: "end returned workspace sessions"
      )
    }
  }

  private func captureRemotePaths(
    _ workspace: RemoteWorkspaceRecord,
    baseState: RemoteHandoffStateFingerprint
  ) async throws -> RemotePathCheckpoint {
    let token = UUID().uuidString.lowercased()
    let output = try await runSSH(
      workspace.remote.target,
      script: Self.pathCaptureScript(workspace: workspace, baseState: baseState, token: token),
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 60
    )
    guard output.status == 0 else {
      throw Self.remoteFailure(output, executable: sshExecutable, operation: "inspect return paths")
    }

    let root = try makeTemporaryDirectory(named: "Feather Remote Return Paths")
    defer { try? fileManager.removeItem(at: root) }
    try await extractTopLevelArchive(output.stdout, to: root)
    let branch = try readSmallText(root.appendingPathComponent("branch"))
    let head = try readSmallText(root.appendingPathComponent("head"))
    let paths = try Data(contentsOf: root.appendingPathComponent("untracked.paths"))
    guard branch == baseState.branch, Self.isObjectID(head) else {
      throw RemoteHandoffError.invalidGitState
    }
    return RemotePathCheckpoint(branch: branch, headCommit: head, untrackedPaths: paths)
  }

  private func captureRemotePayload(
    _ workspace: RemoteWorkspaceRecord,
    baseState: RemoteHandoffStateFingerprint,
    pathCheckpoint: RemotePathCheckpoint
  ) async throws -> RemotePayloadCapture {
    let token = UUID().uuidString.lowercased()
    let output = try await runSSH(
      workspace.remote.target,
      script: Self.payloadCaptureScript(
        workspace: workspace,
        baseState: baseState,
        pathCheckpoint: pathCheckpoint,
        token: token
      ),
      standardInput: pathCheckpoint.untrackedPaths,
      maximumOutputBytes: limits.maximumTransferBytes,
      timeout: 180
    )
    guard output.status == 0 else {
      throw Self.remoteFailure(output, executable: sshExecutable, operation: "capture return state")
    }

    let root = try makeTemporaryDirectory(named: "Feather Remote Return Payload")
    defer { try? fileManager.removeItem(at: root) }
    let captureRoot = root.appendingPathComponent("capture", isDirectory: true)
    try fileManager.createDirectory(at: captureRoot, withIntermediateDirectories: true)
    try await extractTopLevelArchive(output.stdout, to: captureRoot)
    return try await buildTransferPayload(
      from: captureRoot,
      baseState: baseState,
      expectedPaths: pathCheckpoint
    )
  }

  private func buildTransferPayload(
    from captureRoot: URL,
    baseState: RemoteHandoffStateFingerprint,
    expectedPaths: RemotePathCheckpoint
  ) async throws -> RemotePayloadCapture {
    let branch = try readSmallText(captureRoot.appendingPathComponent("branch"))
    let headCommit = try readSmallText(captureRoot.appendingPathComponent("head"))
    let unpublishedText = try readSmallText(
      captureRoot.appendingPathComponent("unpublished.count")
    )
    guard branch == expectedPaths.branch, headCommit == expectedPaths.headCommit,
      let unpublishedCommitCount = Int(unpublishedText), unpublishedCommitCount >= 0,
      Self.isObjectID(headCommit)
    else { throw RemoteHandoffError.remoteReturnChanged }

    let status = try boundedData(
      at: captureRoot.appendingPathComponent("status.snapshot"),
      maximumBytes: limits.maximumMetadataBytes
    )
    let indexPatch = try boundedData(
      at: captureRoot.appendingPathComponent("index.patch"),
      maximumBytes: limits.maximumPatchBytes
    )
    let worktreePatch = try boundedData(
      at: captureRoot.appendingPathComponent("worktree.patch"),
      maximumBytes: limits.maximumPatchBytes
    )
    let stagedPaths = try boundedData(
      at: captureRoot.appendingPathComponent("staged.paths"),
      maximumBytes: limits.maximumMetadataBytes
    )
    let unstagedPaths = try boundedData(
      at: captureRoot.appendingPathComponent("unstaged.paths"),
      maximumBytes: limits.maximumMetadataBytes
    )
    let untrackedPaths = try boundedData(
      at: captureRoot.appendingPathComponent("untracked.paths"),
      maximumBytes: limits.maximumMetadataBytes
    )
    guard untrackedPaths == expectedPaths.untrackedPaths else {
      throw RemoteHandoffError.remoteReturnChanged
    }

    let paths = try RemoteGitStateTransfer.nulSeparatedPaths(untrackedPaths)
    for path in paths { try RemoteTransferPathPolicy.validate(path) }
    let untrackedArchive = try boundedData(
      at: captureRoot.appendingPathComponent("untracked.tar"),
      maximumBytes: limits.maximumTransferBytes
    )
    let expectedUntrackedArchiveHash = try readSmallText(
      captureRoot.appendingPathComponent("untracked.tar.sha256")
    )
    let untrackedArchiveHash = RemoteGitStateTransfer.sha256(untrackedArchive)
    guard expectedUntrackedArchiveHash == untrackedArchiveHash else {
      throw RemoteHandoffError.invalidGitState
    }

    let payloadRoot = captureRoot.deletingLastPathComponent().appendingPathComponent(
      "payload",
      isDirectory: true
    )
    let untrackedRoot = payloadRoot.appendingPathComponent("untracked", isDirectory: true)
    try fileManager.createDirectory(at: untrackedRoot, withIntermediateDirectories: true)
    try await extractUntrackedArchive(untrackedArchive, paths: paths, to: untrackedRoot)
    let entries = try RemoteGitStateTransfer.captureUntrackedEntries(
      paths: paths,
      worktreePath: untrackedRoot.path,
      copyRoot: nil,
      limits: limits,
      fileManager: fileManager
    )
    try validateExtractedPaths(paths, at: untrackedRoot)
    let untrackedEntries = Data(entries.flatMap { $0.verificationLine.utf8 })
    let untrackedBytes = entries.reduce(Int64(0)) { $0 + $1.byteCount }
    let staged = try RemoteGitStateTransfer.nulSeparatedPaths(stagedPaths)
    let unstaged = try RemoteGitStateTransfer.nulSeparatedPaths(unstagedPaths)

    try status.write(to: payloadRoot.appendingPathComponent("status.snapshot"))
    try indexPatch.write(to: payloadRoot.appendingPathComponent("index.patch"))
    try worktreePatch.write(to: payloadRoot.appendingPathComponent("worktree.patch"))
    try untrackedPaths.write(to: payloadRoot.appendingPathComponent("untracked.paths"))
    try untrackedEntries.write(to: payloadRoot.appendingPathComponent("untracked.entries"))

    let bundleURL = captureRoot.appendingPathComponent("commits.bundle")
    let bundleSHA256: String?
    if unpublishedCommitCount > 0 {
      guard fileManager.fileExists(atPath: bundleURL.path) else {
        throw RemoteHandoffError.invalidGitState
      }
      let bundle = try boundedData(at: bundleURL, maximumBytes: limits.maximumTransferBytes)
      let destination = payloadRoot.appendingPathComponent("commits.bundle")
      try bundle.write(to: destination)
      bundleSHA256 = RemoteGitStateTransfer.sha256(bundle)
    } else {
      guard !fileManager.fileExists(atPath: bundleURL.path) else {
        throw RemoteHandoffError.invalidGitState
      }
      bundleSHA256 = nil
    }

    let state = RemoteHandoffStateFingerprint(
      branch: branch,
      baseCommit: baseState.baseCommit,
      headCommit: headCommit,
      publishedCommit: baseState.publishedCommit,
      statusSHA256: RemoteGitStateTransfer.sha256(status),
      indexPatchSHA256: RemoteGitStateTransfer.sha256(indexPatch),
      worktreePatchSHA256: RemoteGitStateTransfer.sha256(worktreePatch),
      untrackedPathsSHA256: RemoteGitStateTransfer.sha256(untrackedPaths),
      untrackedEntriesSHA256: RemoteGitStateTransfer.sha256(untrackedEntries),
      stagedPathCount: Set(staged).count,
      unstagedPathCount: Set(unstaged).count,
      untrackedFileCount: entries.count,
      untrackedBytes: untrackedBytes,
      unpublishedCommitCount: unpublishedCommitCount
    )
    let artifactBytes = try RemoteGitStateTransfer.directoryByteCount(
      payloadRoot,
      fileManager: fileManager
    )
    let manifest = RemoteHandoffManifest(
      state: state,
      bundleSHA256: bundleSHA256,
      artifactBytes: artifactBytes
    )
    let manifestData = try Self.encodeManifest(manifest)
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
      throw Self.commandFailure(
        archiveOutput,
        executable: tarExecutable,
        arguments: ["create verified remote return payload"]
      )
    }
    let payload = RemoteGitStateTransferPayload(
      origin: "",
      preflight: RemoteHandoffPreflight(
        state: state,
        transferBytes: Int64(archiveOutput.stdout.count)
      ),
      manifest: manifest,
      manifestSHA256: RemoteGitStateTransfer.sha256(manifestData),
      archive: archiveOutput.stdout,
      archiveSHA256: RemoteGitStateTransfer.sha256(archiveOutput.stdout)
    )
    return RemotePayloadCapture(
      payload: payload,
      untrackedArchiveSHA256: untrackedArchiveHash
    )
  }

  private func normalizedSessionIDs(
    _ values: [String],
    workspace: RemoteWorkspaceRecord
  ) throws -> [String] {
    var values = values
    values.append(RemoteHandoffService.workspaceSessionID(workspace.id))
    let normalized = try Array(Set(values)).map(SSHRemoteTargetValidator.validateSessionID).sorted()
    guard normalized.count <= RemoteWorkspaceOwnershipValidator.maximumRecordedSessionCount else {
      throw RemoteHandoffError.invalidOwnershipMetadata
    }
    return normalized
  }

  private func activeSessionIDs(
    _ sessionIDs: [String],
    workspace: RemoteWorkspaceRecord
  ) async throws -> [String] {
    guard !sessionIDs.isEmpty else { return [] }
    let snapshots = try await SSHTmuxBackend(
      remote: workspace.remote,
      sshExecutable: sshExecutable
    ).runtimeSnapshots()
    let active = Set(snapshots.map(\.sessionID))
    return sessionIDs.filter(active.contains)
  }

  private func verifyRemoteOwnership(_ workspace: RemoteWorkspaceRecord) async throws {
    let output = try await runSSH(
      workspace.remote.target,
      script: """
        set -eu
        \(RemoteHandoffService.ownershipCheckScript(workspace))
        printf verified
        """,
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 30
    )
    guard output.status == 0, output.stdoutText == "verified" else {
      throw RemoteHandoffError.remoteCleanupRefused
    }
  }

  private func runSSH(
    _ target: SSHRemoteTarget,
    script: String,
    standardInput: Data? = nil,
    maximumOutputBytes: Int,
    timeout: TimeInterval
  ) async throws -> BoundedCommandOutput {
    try await runner.run(
      sshExecutable,
      arguments: RemoteHandoffService.noninteractiveSSHArguments(target: target) + [
        target.host, script,
      ],
      environment: ["GIT_TERMINAL_PROMPT": "0"],
      standardInput: standardInput,
      maximumOutputBytes: maximumOutputBytes,
      timeout: timeout
    )
  }

  private func extractTopLevelArchive(_ archive: Data, to destination: URL) async throws {
    let archiveURL = destination.deletingLastPathComponent().appendingPathComponent(
      "\(UUID().uuidString).tar"
    )
    try archive.write(to: archiveURL)
    defer { try? fileManager.removeItem(at: archiveURL) }
    let output = try await runner.run(
      tarExecutable,
      arguments: ["-xf", archiveURL.path, "-C", destination.path],
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 60
    )
    guard output.status == 0 else {
      throw Self.commandFailure(
        output,
        executable: tarExecutable,
        arguments: ["extract remote return metadata"]
      )
    }
  }

  private func extractUntrackedArchive(
    _ archive: Data,
    paths: [String],
    to destination: URL
  ) async throws {
    guard paths.count <= limits.maximumUntrackedFiles else {
      throw RemoteHandoffError.tooManyUntrackedFiles(limits.maximumUntrackedFiles)
    }
    let archiveURL = destination.deletingLastPathComponent().appendingPathComponent(
      "untracked-\(UUID().uuidString).tar"
    )
    try archive.write(to: archiveURL)
    defer { try? fileManager.removeItem(at: archiveURL) }
    let output = try await runner.run(
      tarExecutable,
      arguments: ["-xf", archiveURL.path, "-C", destination.path],
      maximumOutputBytes: limits.maximumMetadataBytes,
      timeout: 60
    )
    guard output.status == 0 else {
      throw Self.commandFailure(
        output,
        executable: tarExecutable,
        arguments: ["extract validated remote untracked files"]
      )
    }
  }

  private func validateExtractedPaths(_ expectedPaths: [String], at root: URL) throws {
    let expected = Set(expectedPaths)
    var actual: Set<String> = []
    for path in try fileManager.subpathsOfDirectory(atPath: root.path) {
      try RemoteTransferPathPolicy.validate(path)
      let attributes = try fileManager.attributesOfItem(
        atPath: root.appendingPathComponent(path).path
      )
      switch attributes[.type] as? FileAttributeType {
      case .typeRegular, .typeSymbolicLink:
        actual.insert(path)
      case .typeDirectory:
        break
      default:
        throw RemoteHandoffError.unsupportedUntrackedFile(path)
      }
    }
    guard actual == expected else { throw RemoteHandoffError.invalidGitState }
  }

  private func makeTemporaryDirectory(named name: String) throws -> URL {
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "\(name) \(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }

  private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    guard byteCount >= 0, byteCount <= Int64(maximumBytes) else {
      throw RemoteHandoffError.transferTooLarge(maximumBytes)
    }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
  }

  private func readSmallText(_ url: URL) throws -> String {
    let data = try boundedData(at: url, maximumBytes: 4 * 1_024)
    guard let value = String(data: data, encoding: .utf8) else {
      throw RemoteHandoffError.invalidGitState
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func encodeManifest(_ manifest: RemoteHandoffManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest)
  }

  private static func commandFailure(
    _ output: BoundedCommandOutput,
    executable: String,
    arguments: [String]
  ) -> BoundedCommandFailure {
    BoundedCommandFailure(
      executable: executable,
      arguments: arguments,
      status: output.status,
      stderr: output.stderrText
    )
  }

  private static func remoteFailure(
    _ output: BoundedCommandOutput,
    executable: String,
    operation: String
  ) -> Error {
    if output.status == 42 { return RemoteHandoffError.remoteCleanupRefused }
    return commandFailure(output, executable: executable, arguments: [operation])
  }

  private static func isObjectID(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64)
      && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      }
  }

  private static func pathCaptureScript(
    workspace: RemoteWorkspaceRecord,
    baseState: RemoteHandoffStateFingerprint,
    token: String
  ) -> String {
    let controlRoot = (workspace.remote.tmuxConfigPath as NSString).deletingLastPathComponent
    let capture = "\(controlRoot)/returns/\(workspace.id.uuidString.lowercased())-\(token).paths"
    let captureParent = (capture as NSString).deletingLastPathComponent
    return """
      set -eu
      directory=\(POSIXShell.quote(workspace.remote.workingDirectory))
      capture=\(POSIXShell.quote(capture))
      token=\(POSIXShell.quote(token))
      \(RemoteHandoffService.ownershipCheckScript(workspace))
      test ! -e "$capture"
      umask 077
      mkdir -p -- \(POSIXShell.quote(captureParent))
      mkdir -- "$capture"
      printf %s "$token" > "$capture/feather-owner"
      cleanup_return_capture() {
        status=$?
        trap - EXIT HUP INT TERM
        if [ -f "$capture/feather-owner" ] && [ "$(cat -- "$capture/feather-owner")" = "$token" ]; then
          rm -rf -- "$capture"
        fi
        exit "$status"
      }
      trap cleanup_return_capture EXIT HUP INT TERM
      branch=$(git -C "$directory" symbolic-ref --quiet --short HEAD)
      test "$branch" = \(POSIXShell.quote(baseState.branch))
      head=$(git -C "$directory" rev-parse --verify HEAD^{commit})
      git -C "$directory" cat-file -e \(POSIXShell.quote(baseState.baseCommit + "^{commit}"))
      git -C "$directory" merge-base --is-ancestor \(POSIXShell.quote(baseState.baseCommit)) "$head"
      printf %s "$branch" > "$capture/branch"
      printf %s "$head" > "$capture/head"
      git -C "$directory" ls-files --others --exclude-standard -z > "$capture/untracked.paths"
      git -C "$directory" ls-files --others --exclude-standard -z > "$capture/untracked.verify"
      cmp -s "$capture/untracked.paths" "$capture/untracked.verify"
      test "$(git -C "$directory" rev-parse --verify HEAD^{commit})" = "$head"
      tar -C "$capture" -cf - branch head untracked.paths
      """
  }

  private static func payloadCaptureScript(
    workspace: RemoteWorkspaceRecord,
    baseState: RemoteHandoffStateFingerprint,
    pathCheckpoint: RemotePathCheckpoint,
    token: String
  ) -> String {
    let controlRoot = (workspace.remote.tmuxConfigPath as NSString).deletingLastPathComponent
    let capture = "\(controlRoot)/returns/\(workspace.id.uuidString.lowercased())-\(token).payload"
    let captureParent = (capture as NSString).deletingLastPathComponent
    let diff =
      "-c diff.mnemonicPrefix=false -c diff.noprefix=false diff --binary --full-index "
      + "--no-color --no-ext-diff --no-textconv --no-renames --src-prefix=a/ --dst-prefix=b/"
    return """
      set -eu
      directory=\(POSIXShell.quote(workspace.remote.workingDirectory))
      capture=\(POSIXShell.quote(capture))
      token=\(POSIXShell.quote(token))
      \(RemoteHandoffService.ownershipCheckScript(workspace))
      command -v git >/dev/null
      command -v tar >/dev/null
      command -v cmp >/dev/null
      command -v awk >/dev/null
      command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null
      sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
          sha256sum "$1" | awk '{print $1}'
        else
          shasum -a 256 "$1" | awk '{print $1}'
        fi
      }
      test ! -e "$capture"
      umask 077
      mkdir -p -- \(POSIXShell.quote(captureParent))
      mkdir -- "$capture"
      printf %s "$token" > "$capture/feather-owner"
      cleanup_return_capture() {
        status=$?
        trap - EXIT HUP INT TERM
        if [ -f "$capture/feather-owner" ] && [ "$(cat -- "$capture/feather-owner")" = "$token" ]; then
          rm -rf -- "$capture"
        fi
        exit "$status"
      }
      trap cleanup_return_capture EXIT HUP INT TERM
      cat > "$capture/expected-untracked.paths"
      branch=$(git -C "$directory" symbolic-ref --quiet --short HEAD)
      test "$branch" = \(POSIXShell.quote(pathCheckpoint.branch))
      head=$(git -C "$directory" rev-parse --verify HEAD^{commit})
      test "$head" = \(POSIXShell.quote(pathCheckpoint.headCommit))
      git -C "$directory" cat-file -e \(POSIXShell.quote(baseState.baseCommit + "^{commit}"))
      git -C "$directory" merge-base --is-ancestor \(POSIXShell.quote(baseState.baseCommit)) "$head"
      printf %s "$branch" > "$capture/branch"
      printf %s "$head" > "$capture/head"
      git -C "$directory" status --porcelain=v1 -z --untracked-files=all --no-renames > "$capture/status.snapshot"
      git -C "$directory" \(diff) --cached > "$capture/index.patch"
      git -C "$directory" \(diff) > "$capture/worktree.patch"
      git -C "$directory" diff --name-only --no-renames -z --cached > "$capture/staged.paths"
      git -C "$directory" diff --name-only --no-renames -z > "$capture/unstaged.paths"
      git -C "$directory" ls-files --others --exclude-standard -z > "$capture/untracked.paths"
      cmp -s "$capture/expected-untracked.paths" "$capture/untracked.paths"
      unpublished=$(git -C "$directory" rev-list --count \(POSIXShell.quote(baseState.baseCommit + ".."))"$head")
      printf %s "$unpublished" > "$capture/unpublished.count"
      tar -C "$directory" -cf "$capture/untracked.tar" --null -T "$capture/untracked.paths"
      sha256_file "$capture/untracked.tar" > "$capture/untracked.tar.sha256"
      if [ "$unpublished" -gt 0 ]; then
        git -C "$directory" bundle create "$capture/commits.bundle" HEAD \(POSIXShell.quote("^" + baseState.baseCommit))
        test "$(git -C "$directory" bundle list-heads "$capture/commits.bundle" | awk 'NR == 1 {print $1}')" = "$head"
      fi
      test "$(git -C "$directory" symbolic-ref --quiet --short HEAD)" = "$branch"
      test "$(git -C "$directory" rev-parse --verify HEAD^{commit})" = "$head"
      git -C "$directory" status --porcelain=v1 -z --untracked-files=all --no-renames > "$capture/status.verify"
      git -C "$directory" \(diff) --cached > "$capture/index.verify"
      git -C "$directory" \(diff) > "$capture/worktree.verify"
      git -C "$directory" diff --name-only --no-renames -z --cached > "$capture/staged.verify"
      git -C "$directory" diff --name-only --no-renames -z > "$capture/unstaged.verify"
      git -C "$directory" ls-files --others --exclude-standard -z > "$capture/untracked.verify"
      cmp -s "$capture/status.snapshot" "$capture/status.verify"
      cmp -s "$capture/index.patch" "$capture/index.verify"
      cmp -s "$capture/worktree.patch" "$capture/worktree.verify"
      cmp -s "$capture/staged.paths" "$capture/staged.verify"
      cmp -s "$capture/unstaged.paths" "$capture/unstaged.verify"
      cmp -s "$capture/untracked.paths" "$capture/untracked.verify"
      tar -C "$directory" -cf "$capture/untracked.verify.tar" --null -T "$capture/untracked.paths"
      test "$(sha256_file "$capture/untracked.verify.tar")" = "$(cat -- "$capture/untracked.tar.sha256")"
      if [ "$unpublished" -gt 0 ]; then
        tar -C "$capture" -cf - branch head unpublished.count status.snapshot index.patch worktree.patch staged.paths unstaged.paths untracked.paths untracked.tar untracked.tar.sha256 commits.bundle
      else
        tar -C "$capture" -cf - branch head unpublished.count status.snapshot index.patch worktree.patch staged.paths unstaged.paths untracked.paths untracked.tar untracked.tar.sha256
      fi
      """
  }

  private static func payloadVerificationScript(
    workspace: RemoteWorkspaceRecord,
    state: RemoteHandoffStateFingerprint,
    untrackedArchiveSHA256: String,
    token: String
  ) -> String {
    let controlRoot = (workspace.remote.tmuxConfigPath as NSString).deletingLastPathComponent
    let capture =
      "\(controlRoot)/returns/\(workspace.id.uuidString.lowercased())-\(token).verify"
    let captureParent = (capture as NSString).deletingLastPathComponent
    let diff =
      "-c diff.mnemonicPrefix=false -c diff.noprefix=false diff --binary --full-index "
      + "--no-color --no-ext-diff --no-textconv --no-renames --src-prefix=a/ --dst-prefix=b/"
    return """
      set -eu
      directory=\(POSIXShell.quote(workspace.remote.workingDirectory))
      capture=\(POSIXShell.quote(capture))
      token=\(POSIXShell.quote(token))
      \(RemoteHandoffService.ownershipCheckScript(workspace))
      command -v git >/dev/null
      command -v tar >/dev/null
      command -v cmp >/dev/null
      command -v awk >/dev/null
      command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null
      sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
          sha256sum "$1" | awk '{print $1}'
        else
          shasum -a 256 "$1" | awk '{print $1}'
        fi
      }
      test ! -e "$capture"
      umask 077
      mkdir -p -- \(POSIXShell.quote(captureParent))
      mkdir -- "$capture"
      printf %s "$token" > "$capture/feather-owner"
      cleanup_return_verification() {
        status=$?
        trap - EXIT HUP INT TERM
        if [ -f "$capture/feather-owner" ] && [ "$(cat -- "$capture/feather-owner")" = "$token" ]; then
          rm -rf -- "$capture"
        fi
        exit "$status"
      }
      trap cleanup_return_verification EXIT HUP INT TERM
      cat > "$capture/expected-untracked.paths"
      test "$(git -C "$directory" symbolic-ref --quiet --short HEAD)" = \(POSIXShell.quote(state.branch))
      head=$(git -C "$directory" rev-parse --verify HEAD^{commit})
      test "$head" = \(POSIXShell.quote(state.headCommit))
      git -C "$directory" merge-base --is-ancestor \(POSIXShell.quote(state.baseCommit)) "$head"
      test "$(git -C "$directory" rev-list --count \(POSIXShell.quote(state.baseCommit + ".."))"$head")" -eq \(state.unpublishedCommitCount)
      git -C "$directory" status --porcelain=v1 -z --untracked-files=all --no-renames > "$capture/status"
      git -C "$directory" \(diff) --cached > "$capture/index"
      git -C "$directory" \(diff) > "$capture/worktree"
      git -C "$directory" ls-files --others --exclude-standard -z > "$capture/untracked.paths"
      cmp -s "$capture/expected-untracked.paths" "$capture/untracked.paths"
      test "$(sha256_file "$capture/status")" = \(POSIXShell.quote(state.statusSHA256))
      test "$(sha256_file "$capture/index")" = \(POSIXShell.quote(state.indexPatchSHA256))
      test "$(sha256_file "$capture/worktree")" = \(POSIXShell.quote(state.worktreePatchSHA256))
      test "$(sha256_file "$capture/untracked.paths")" = \(POSIXShell.quote(state.untrackedPathsSHA256))
      tar -C "$directory" -cf "$capture/untracked.tar" --null -T "$capture/untracked.paths"
      test "$(sha256_file "$capture/untracked.tar")" = \(POSIXShell.quote(untrackedArchiveSHA256))
      test "$(git -C "$directory" rev-parse --verify HEAD^{commit})" = "$head"
      git -C "$directory" status --porcelain=v1 -z --untracked-files=all --no-renames > "$capture/status.verify"
      git -C "$directory" \(diff) --cached > "$capture/index.verify"
      git -C "$directory" \(diff) > "$capture/worktree.verify"
      git -C "$directory" ls-files --others --exclude-standard -z > "$capture/untracked.verify"
      cmp -s "$capture/status" "$capture/status.verify"
      cmp -s "$capture/index" "$capture/index.verify"
      cmp -s "$capture/worktree" "$capture/worktree.verify"
      cmp -s "$capture/untracked.paths" "$capture/untracked.verify"
      tar -C "$directory" -cf "$capture/untracked.verify.tar" --null -T "$capture/untracked.paths"
      test "$(sha256_file "$capture/untracked.verify.tar")" = \(POSIXShell.quote(untrackedArchiveSHA256))
      printf 'current:%s\n' "$token"
      """
  }

  private static func endSessionsScript(
    workspace: RemoteWorkspaceRecord,
    sessionIDs: [String],
    token: String
  ) -> String {
    let commands = sessionIDs.map { sessionID in
      let session = POSIXShell.quote(sessionID)
      return """
        if tmux -L \(POSIXShell.quote(workspace.remote.tmuxSocketName)) -f \(POSIXShell.quote(workspace.remote.tmuxConfigPath)) has-session -t \(session) >/dev/null 2>&1; then
          tmux -L \(POSIXShell.quote(workspace.remote.tmuxSocketName)) -f \(POSIXShell.quote(workspace.remote.tmuxConfigPath)) kill-session -t \(session)
        fi
        ! tmux -L \(POSIXShell.quote(workspace.remote.tmuxSocketName)) -f \(POSIXShell.quote(workspace.remote.tmuxConfigPath)) has-session -t \(session) >/dev/null 2>&1
        """
    }.joined(separator: "\n")
    return """
      set -eu
      \(RemoteHandoffService.ownershipCheckScript(workspace))
      command -v tmux >/dev/null
      \(commands)
      \(RemoteHandoffService.ownershipCheckScript(workspace))
      printf 'ended:%s\n' \(POSIXShell.quote(token))
      """
  }

  private static func cleanupScript(
    workspace: RemoteWorkspaceRecord,
    ownership: RemoteWorkspaceOwnership,
    sessionIDs: [String],
    endSessions: Bool,
    receiptToken: String
  ) -> String {
    let sessionCommands = sessionIDs.map { sessionID in
      let session = POSIXShell.quote(sessionID)
      if endSessions {
        return """
          if tmux -L \(POSIXShell.quote(workspace.remote.tmuxSocketName)) -f \(POSIXShell.quote(workspace.remote.tmuxConfigPath)) has-session -t \(session) >/dev/null 2>&1; then
            tmux -L \(POSIXShell.quote(workspace.remote.tmuxSocketName)) -f \(POSIXShell.quote(workspace.remote.tmuxConfigPath)) kill-session -t \(session)
          fi
          ! tmux -L \(POSIXShell.quote(workspace.remote.tmuxSocketName)) -f \(POSIXShell.quote(workspace.remote.tmuxConfigPath)) has-session -t \(session) >/dev/null 2>&1
          """
      }
      return """
        if tmux -L \(POSIXShell.quote(workspace.remote.tmuxSocketName)) -f \(POSIXShell.quote(workspace.remote.tmuxConfigPath)) has-session -t \(session) >/dev/null 2>&1; then exit 43; fi
        """
    }.joined(separator: "\n")
    let checkoutMarker = workspace.remote.workingDirectory + "/.git/feather-owner"
    let manifestPath = workspace.remote.workingDirectory + "/.git/feather-handoff/manifest.json"
    let manifestHash = workspace.handoff.flatMap(RemoteHandoffService.manifestSHA256) ?? ""
    return """
      set -eu
      directory=\(POSIXShell.quote(workspace.remote.workingDirectory))
      marker=\(POSIXShell.quote(ownership.markerPath))
      checkout_marker=\(POSIXShell.quote(checkoutMarker))
      manifest=\(POSIXShell.quote(manifestPath))
      ownership_token=\(POSIXShell.quote(ownership.token))
      command -v tmux >/dev/null
      command -v awk >/dev/null
      command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null
      sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
          sha256sum "$1" | awk '{print $1}'
        else
          shasum -a 256 "$1" | awk '{print $1}'
        fi
      }
      test -f "$marker" || exit 42
      test "$(cat -- "$marker")" = "$ownership_token" || exit 42
      test -d "$directory" || exit 42
      test -f "$checkout_marker" || exit 42
      test "$(cat -- "$checkout_marker")" = "$ownership_token" || exit 42
      test -f "$manifest" || exit 42
      test "$(sha256_file "$manifest")" = \(POSIXShell.quote(manifestHash)) || exit 42
      \(sessionCommands)
      test "$(cat -- "$marker")" = "$ownership_token" || exit 42
      test "$(cat -- "$checkout_marker")" = "$ownership_token" || exit 42
      test "$(sha256_file "$manifest")" = \(POSIXShell.quote(manifestHash)) || exit 42
      rm -rf -- "$directory"
      rm -f -- "$marker"
      test ! -e "$directory"
      test ! -e "$marker"
      printf 'cleaned:%s\n' \(POSIXShell.quote(receiptToken))
      """
  }
}
