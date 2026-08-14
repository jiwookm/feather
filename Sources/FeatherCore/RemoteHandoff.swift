import CryptoKit
import Foundation

enum RemoteHandoffError: LocalizedError, Equatable, Sendable {
  case invalidProfileName
  case invalidHost
  case invalidPort
  case invalidRootPath
  case invalidSession
  case invalidOwnershipMetadata
  case detachedHead
  case missingOrigin
  case credentialBearingOrigin
  case checkpointChanged(String)
  case originFetchRequired
  case remoteBranchDiverged
  case invalidGitState
  case unsupportedUntrackedPath(String)
  case unsupportedUntrackedFile(String)
  case sensitiveUntrackedPath(String)
  case tooManyUntrackedFiles(Int)
  case untrackedFileTooLarge(String, Int64)
  case untrackedFilesTooLarge(Int64)
  case unpublishedObjectsTooLarge(Int64)
  case transferTooLarge(Int)
  case cleanupUnverified(String)
  case remoteReturnUnavailable
  case localReturnDiverged(String)
  case localIgnoredPathConflict(String)
  case remoteReturnChanged
  case returnRecoveryFailed(String)
  case remoteCleanupRefused
  case activeRemoteSessions(Int)

  var errorDescription: String? {
    switch self {
    case .invalidProfileName:
      "Enter a name for this SSH profile."
    case .invalidHost:
      "Enter an SSH host or alias using letters, numbers, `.`, `-`, `_`, `@`, `:`, or brackets."
    case .invalidPort:
      "The SSH port must be between 1 and 65535."
    case .invalidRootPath:
      "The remote root must be an absolute path below `/`, without `.` or `..` components."
    case .invalidSession:
      "This terminal has invalid session metadata. Recreate the terminal before using it remotely."
    case .invalidOwnershipMetadata:
      "The saved remote workspace ownership metadata is invalid. Feather will not operate on it."
    case .detachedHead:
      "Remote workspace setup requires a named Git branch."
    case .missingOrigin:
      "Remote workspace setup requires an `origin` remote."
    case .credentialBearingOrigin:
      "Feather will not send an origin URL containing embedded credentials. Use SSH configuration or a Git credential helper instead."
    case .checkpointChanged(let path):
      "The local checkpoint changed while Feather prepared the remote workspace. Nothing was made authoritative: \(path)"
    case .originFetchRequired:
      "Fetch origin before handing off this unpublished branch so Feather can identify a remote base commit."
    case .remoteBranchDiverged:
      "The branch on origin is not an ancestor of this checkout. Fetch and resolve the divergence before remote handoff."
    case .invalidGitState:
      "Git returned state Feather could not verify. The local checkout was left authoritative."
    case .unsupportedUntrackedPath(let path):
      "The untracked path cannot be transferred safely: \(path)"
    case .unsupportedUntrackedFile(let path):
      "Only regular files and symbolic links can be transferred as untracked state: \(path)"
    case .sensitiveUntrackedPath(let path):
      "Feather will not transfer a likely credential file. Remove it or add it to .gitignore first: \(path)"
    case .tooManyUntrackedFiles(let limit):
      "Remote handoff supports at most \(limit) untracked files. Commit, ignore, or remove some files first."
    case .untrackedFileTooLarge(let path, let limit):
      "The untracked file exceeds Feather's \(Self.byteDescription(limit)) safety limit: \(path)"
    case .untrackedFilesTooLarge(let limit):
      "Untracked files exceed Feather's \(Self.byteDescription(limit)) handoff safety limit."
    case .unpublishedObjectsTooLarge(let limit):
      "Unpublished Git objects exceed Feather's \(Self.byteDescription(limit)) handoff safety limit."
    case .transferTooLarge(let limit):
      "The remote handoff payload exceeds Feather's \(Self.byteDescription(Int64(limit))) safety limit."
    case .cleanupUnverified(let path):
      "Feather could not verify cleanup after the remote handoff stopped. The local worktree is still authoritative. Reconnect to the host and inspect the Feather-owned path before retrying: \(path)"
    case .remoteReturnUnavailable:
      "This workspace predates verified handoff metadata, so Feather cannot return or delete it automatically. Keep both copies and recover it manually."
    case .localReturnDiverged(let path):
      "The local worktree changed after remote handoff, so Feather refused to overwrite it. Keep both copies, commit or move the local changes, then compare them with the remote workspace before retrying: \(path)"
    case .localIgnoredPathConflict(let path):
      "The returned state would expose or overwrite ignored local data, so Feather kept both copies unchanged. Move or remove the local path before retrying: \(path)"
    case .remoteReturnChanged:
      "The remote checkpoint changed during return. Feather restored the original local checkpoint and kept the remote workspace authoritative. Retry after the remote work is idle."
    case .returnRecoveryFailed(let path):
      "Feather could not restore the original local checkpoint after return stopped. The remote workspace remains intact and authoritative. Do not edit the local copy; recover it from the saved remote workspace: \(path)"
    case .remoteCleanupRefused:
      "Feather could not prove that it owns this remote checkout. The record was kept and nothing was deleted."
    case .activeRemoteSessions(let count):
      "The remote checkout still has \(count) recorded terminal session\(count == 1 ? "" : "s"). Confirm ending them before deleting the Feather-owned checkout."
    }
  }

  private static func byteDescription(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

public struct RemoteWorkspacePreparation: Equatable, Sendable {
  public let remote: SSHRemoteTerminal
  public let ownership: RemoteWorkspaceOwnership
  public let manifest: RemoteHandoffManifest

  public init(
    remote: SSHRemoteTerminal,
    ownership: RemoteWorkspaceOwnership,
    manifest: RemoteHandoffManifest
  ) {
    self.remote = remote
    self.ownership = ownership
    self.manifest = manifest
  }
}

public enum SSHRemoteTargetValidator {
  public static func validate(_ target: SSHRemoteTarget) throws -> SSHRemoteTarget {
    let host = target.host.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-@[]:"))
    guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains)
    else { throw RemoteHandoffError.invalidHost }
    guard (1...65_535).contains(target.port) else { throw RemoteHandoffError.invalidPort }

    let root = target.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = root.split(separator: "/", omittingEmptySubsequences: true)
    guard root.hasPrefix("/"), root != "/", !root.contains("\0"), !root.contains("\n"),
      !components.contains("."), !components.contains("..")
    else { throw RemoteHandoffError.invalidRootPath }

    return SSHRemoteTarget(
      host: host,
      port: target.port,
      rootPath: "/" + components.joined(separator: "/")
    )
  }

  static func validateSessionID(_ value: String) throws -> String {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )
    guard !value.isEmpty, value.utf8.count <= 128,
      value.unicodeScalars.allSatisfy(allowed.contains)
    else { throw RemoteHandoffError.invalidSession }
    return value
  }
}

public enum SSHRemoteProfileValidator {
  public static func validate(
    id: UUID = UUID(),
    name: String,
    target: SSHRemoteTarget
  ) throws -> SSHRemoteProfile {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
      throw RemoteHandoffError.invalidProfileName
    }
    return SSHRemoteProfile(
      id: id,
      name: name,
      target: try SSHRemoteTargetValidator.validate(target)
    )
  }
}

public enum RemoteWorkspaceOwnershipValidator {
  static let maximumRecordedSessionCount = 10_000

  public static func validate(_ workspace: RemoteWorkspaceRecord) throws {
    let target = try SSHRemoteTargetValidator.validate(workspace.remote.target)
    let controlRoot = (workspace.remote.tmuxConfigPath as NSString).deletingLastPathComponent
    let worktreesRoot = target.rootPath + "/worktrees"
    let ownershipRoot = controlRoot + "/workspaces"
    let controlName = (controlRoot as NSString).lastPathComponent
    guard target == workspace.remote.target,
      isStrictDescendant(workspace.remote.workingDirectory, of: worktreesRoot),
      (workspace.remote.workingDirectory as NSString).deletingLastPathComponent == worktreesRoot,
      isStrictDescendant(controlRoot, of: target.rootPath),
      (controlRoot as NSString).deletingLastPathComponent == target.rootPath,
      controlName == ".feather" || controlName.hasPrefix(".feather-"),
      (workspace.remote.tmuxConfigPath as NSString).lastPathComponent == "tmux.conf",
      !workspace.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      workspace.profileName.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      })
    else { throw RemoteHandoffError.invalidOwnershipMetadata }

    if let handoff = workspace.handoff {
      guard workspace.ownership != nil, isValidManifest(handoff) else {
        throw RemoteHandoffError.invalidOwnershipMetadata
      }
    }
    if let returned = workspace.returned {
      let canonicalSessionIDs = Array(Set(returned.cleanupSessionIDs)).sorted()
      guard let handoff = workspace.handoff, workspace.ownership != nil,
        isValidManifest(returned.manifest),
        returned.cleanupSessionIDs.count <= maximumRecordedSessionCount,
        returned.cleanupSessionIDs == canonicalSessionIDs,
        returned.cleanupSessionIDs.contains(RemoteHandoffService.workspaceSessionID(workspace.id)),
        returned.manifest.state.branch == handoff.state.branch,
        returned.manifest.state.baseCommit == handoff.state.baseCommit,
        returned.manifest.state.publishedCommit == handoff.state.publishedCommit,
        returned.cleanupSessionIDs.allSatisfy({
          (try? SSHRemoteTargetValidator.validateSessionID($0)) != nil
        })
      else { throw RemoteHandoffError.invalidOwnershipMetadata }
    }

    guard let ownership = workspace.ownership else { return }
    let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard !ownership.token.isEmpty, ownership.token.utf8.count <= 128,
      ownership.token.unicodeScalars.allSatisfy(tokenCharacters.contains),
      isStrictDescendant(ownership.markerPath, of: ownershipRoot),
      (ownership.markerPath as NSString).deletingLastPathComponent == ownershipRoot,
      (ownership.markerPath as NSString).pathExtension == "owner"
    else { throw RemoteHandoffError.invalidOwnershipMetadata }
  }

  private static func isStrictDescendant(_ path: String, of parent: String) -> Bool {
    guard path.hasPrefix("/"), parent.hasPrefix("/") else { return false }
    let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true)
    let parentComponents = parent.split(separator: "/", omittingEmptySubsequences: true)
    guard pathComponents.count > parentComponents.count,
      !pathComponents.contains("."), !pathComponents.contains("..")
    else { return false }
    return pathComponents.starts(with: parentComponents)
  }

  private static func isObjectID(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && isLowercaseHex(value)
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && isLowercaseHex(value)
  }

  private static func isLowercaseHex(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  private static func isValidManifest(_ manifest: RemoteHandoffManifest) -> Bool {
    let state = manifest.state
    return manifest.version == RemoteHandoffManifest.currentVersion
      && manifest.artifactBytes >= 0
      && !state.branch.isEmpty
      && state.branch.utf8.count <= 1_024
      && state.branch.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      })
      && isObjectID(state.baseCommit)
      && isObjectID(state.headCommit)
      && (state.publishedCommit.map(isObjectID) ?? true)
      && isSHA256(state.statusSHA256)
      && isSHA256(state.indexPatchSHA256)
      && isSHA256(state.worktreePatchSHA256)
      && isSHA256(state.untrackedPathsSHA256)
      && isSHA256(state.untrackedEntriesSHA256)
      && (manifest.bundleSHA256.map(isSHA256) ?? true)
      && state.stagedPathCount >= 0
      && state.unstagedPathCount >= 0
      && state.untrackedFileCount >= 0
      && state.untrackedBytes >= 0
      && state.unpublishedCommitCount >= 0
  }
}

enum POSIXShell {
  static func quote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

public actor RemoteHandoffService {
  private let runner: BoundedCommandRunner
  private let sshExecutable: String
  private let controlDirectoryName: String
  private let tmuxSocketName: String
  private let limits: RemoteHandoffLimits
  private let stateTransfer: RemoteGitStateTransfer

  public init(
    runner: BoundedCommandRunner = BoundedCommandRunner(),
    gitExecutable: String = "/usr/bin/git",
    sshExecutable: String = "/usr/bin/ssh",
    tarExecutable: String = "/usr/bin/tar",
    controlDirectoryName: String = ".feather",
    tmuxSocketName: String = "feather",
    limits: RemoteHandoffLimits = .standard
  ) {
    self.runner = runner
    self.sshExecutable = sshExecutable
    self.controlDirectoryName = controlDirectoryName
    self.tmuxSocketName = tmuxSocketName
    self.limits = limits
    stateTransfer = RemoteGitStateTransfer(
      runner: runner,
      gitExecutable: gitExecutable,
      tarExecutable: tarExecutable,
      limits: limits
    )
  }

  public func preflightWorkspace(worktreePath: String) async throws -> RemoteHandoffPreflight {
    try await stateTransfer.buildPayload(worktreePath: worktreePath).preflight
  }

  public func prepareWorkspace(
    repository: RepositoryRecord,
    worktreePath: String,
    workspaceID: UUID,
    target: SSHRemoteTarget,
    expectedPreflight: RemoteHandoffPreflight? = nil
  ) async throws -> RemoteWorkspacePreparation {
    let target = try SSHRemoteTargetValidator.validate(target)
    let payload = try await stateTransfer.buildPayload(worktreePath: worktreePath)
    if let expectedPreflight, expectedPreflight.state != payload.preflight.state {
      throw RemoteHandoffError.checkpointChanged(worktreePath)
    }

    let suffix = workspaceID.uuidString.lowercased().prefix(8)
    let repositoryName = Self.slug(repository.displayName)
    let worktreeName = Self.slug(URL(fileURLWithPath: worktreePath).lastPathComponent)
    let destination = "\(target.rootPath)/worktrees/\(repositoryName)-\(worktreeName)-\(suffix)"
    let controlRoot = "\(target.rootPath)/\(controlDirectoryName)"
    let configPath = "\(controlRoot)/tmux.conf"
    let markerPath = "\(controlRoot)/workspaces/\(workspaceID.uuidString.lowercased()).owner"
    let transferRoot = "\(controlRoot)/transfers"
    let transferDirectory = "\(transferRoot)/\(workspaceID.uuidString.lowercased()).payload"
    let stagingDirectory = "\(transferRoot)/\(workspaceID.uuidString.lowercased()).partial"
    let ownershipToken = UUID().uuidString.lowercased()
    let workspaceSessionID = Self.workspaceSessionID(workspaceID)
    let stageScript = Self.stagingScript(
      origin: payload.origin,
      state: payload.manifest.state,
      manifestSHA256: payload.manifestSHA256,
      archiveSHA256: payload.archiveSHA256,
      bundleSHA256: payload.manifest.bundleSHA256,
      transferDirectory: transferDirectory,
      stagingDirectory: stagingDirectory,
      ownershipToken: ownershipToken
    )
    let staged: BoundedCommandOutput
    do {
      staged = try await runner.run(
        sshExecutable,
        arguments: Self.noninteractiveSSHArguments(target: target) + [target.host, stageScript],
        environment: ["GIT_TERMINAL_PROMPT": "0"],
        standardInput: payload.archive,
        maximumOutputBytes: limits.maximumMetadataBytes,
        timeout: 180
      )
    } catch {
      let cleaned = await cleanupRemoteTransfer(
        target: target,
        transferDirectory: transferDirectory,
        stagingDirectory: stagingDirectory,
        ownershipToken: ownershipToken
      )
      guard cleaned else { throw RemoteHandoffError.cleanupUnverified(stagingDirectory) }
      throw error
    }
    guard staged.status == 0,
      Self.hasReceipt("staged:\(ownershipToken)", in: staged.stdoutText)
    else {
      let cleaned = await cleanupRemoteTransfer(
        target: target,
        transferDirectory: transferDirectory,
        stagingDirectory: stagingDirectory,
        ownershipToken: ownershipToken
      )
      guard cleaned else { throw RemoteHandoffError.cleanupUnverified(stagingDirectory) }
      throw BoundedCommandFailure(
        executable: sshExecutable,
        arguments: [target.host, "stage Feather workspace"],
        status: staged.status,
        stderr: staged.stderrText
      )
    }

    do {
      let localState = try await stateTransfer.captureFingerprint(worktreePath: worktreePath)
      guard localState == payload.manifest.state else {
        throw RemoteHandoffError.checkpointChanged(worktreePath)
      }
    } catch {
      let cleaned = await cleanupRemoteTransfer(
        target: target,
        transferDirectory: transferDirectory,
        stagingDirectory: stagingDirectory,
        ownershipToken: ownershipToken
      )
      guard cleaned else { throw RemoteHandoffError.cleanupUnverified(stagingDirectory) }
      throw error
    }

    let finalizeScript = Self.finalizationScript(
      destination: destination,
      controlRoot: controlRoot,
      configPath: configPath,
      markerPath: markerPath,
      stagingDirectory: stagingDirectory,
      ownershipToken: ownershipToken,
      workspaceSessionID: workspaceSessionID,
      tmuxSocketName: tmuxSocketName
    )
    let finalized: BoundedCommandOutput
    do {
      finalized = try await runner.run(
        sshExecutable,
        arguments: Self.noninteractiveSSHArguments(target: target) + [
          target.host, finalizeScript,
        ],
        environment: ["GIT_TERMINAL_PROMPT": "0"],
        maximumOutputBytes: limits.maximumMetadataBytes,
        timeout: 60
      )
    } catch {
      let rolledBack = await rollbackRemoteWorkspace(
        target: target,
        destination: destination,
        configPath: configPath,
        markerPath: markerPath,
        ownershipToken: ownershipToken,
        workspaceSessionID: workspaceSessionID
      )
      let cleaned = await cleanupRemoteTransfer(
        target: target,
        transferDirectory: transferDirectory,
        stagingDirectory: stagingDirectory,
        ownershipToken: ownershipToken
      )
      guard rolledBack, cleaned else {
        throw RemoteHandoffError.cleanupUnverified(destination)
      }
      throw error
    }
    guard finalized.status == 0,
      Self.hasReceipt("active:\(ownershipToken)", in: finalized.stdoutText)
    else {
      let rolledBack = await rollbackRemoteWorkspace(
        target: target,
        destination: destination,
        configPath: configPath,
        markerPath: markerPath,
        ownershipToken: ownershipToken,
        workspaceSessionID: workspaceSessionID
      )
      let cleaned = await cleanupRemoteTransfer(
        target: target,
        transferDirectory: transferDirectory,
        stagingDirectory: stagingDirectory,
        ownershipToken: ownershipToken
      )
      guard rolledBack, cleaned else {
        throw RemoteHandoffError.cleanupUnverified(destination)
      }
      throw BoundedCommandFailure(
        executable: sshExecutable,
        arguments: [target.host, "activate Feather workspace"],
        status: finalized.status,
        stderr: finalized.stderrText
      )
    }

    do {
      let finalState = try await stateTransfer.captureFingerprint(worktreePath: worktreePath)
      guard finalState == payload.manifest.state else {
        throw RemoteHandoffError.checkpointChanged(worktreePath)
      }
    } catch {
      let rolledBack = await rollbackRemoteWorkspace(
        target: target,
        destination: destination,
        configPath: configPath,
        markerPath: markerPath,
        ownershipToken: ownershipToken,
        workspaceSessionID: workspaceSessionID
      )
      guard rolledBack else { throw RemoteHandoffError.cleanupUnverified(destination) }
      throw error
    }

    let remoteTerminal = SSHRemoteTerminal(
      target: target,
      workingDirectory: destination,
      tmuxConfigPath: configPath,
      tmuxSocketName: tmuxSocketName
    )
    return RemoteWorkspacePreparation(
      remote: remoteTerminal,
      ownership: RemoteWorkspaceOwnership(token: ownershipToken, markerPath: markerPath),
      manifest: payload.manifest
    )
  }

  public func checkWorkspace(
    _ workspace: RemoteWorkspaceRecord
  ) async throws -> RemoteWorkspaceRuntimeState {
    do {
      try RemoteWorkspaceOwnershipValidator.validate(workspace)
    } catch {
      return .ownershipMismatch
    }
    let script = Self.ownershipCheckScript(workspace)
    let output = try await runner.run(
      sshExecutable,
      arguments: Self.noninteractiveSSHArguments(target: workspace.remote.target) + [
        workspace.remote.target.host, script,
      ],
      maximumOutputBytes: 128 * 1_024,
      timeout: 15
    )
    switch output.status {
    case 0:
      return .connected
    case 42:
      return .ownershipMismatch
    case 255:
      return .offline
    default:
      throw BoundedCommandFailure(
        executable: sshExecutable,
        arguments: [workspace.remote.target.host, "verify Feather workspace"],
        status: output.status,
        stderr: output.stderrText
      )
    }
  }

  public func checkTarget(_ target: SSHRemoteTarget) async throws {
    let target = try SSHRemoteTargetValidator.validate(target)
    let output = try await runner.run(
      sshExecutable,
      arguments: Self.noninteractiveSSHArguments(target: target) + [
        target.host,
        "command -v git >/dev/null && command -v tmux >/dev/null && command -v tar >/dev/null && command -v base64 >/dev/null && (command -v sha256sum >/dev/null || command -v shasum >/dev/null)",
      ],
      maximumOutputBytes: 128 * 1_024,
      timeout: 15
    )
    guard output.status == 0 else {
      throw BoundedCommandFailure(
        executable: sshExecutable,
        arguments: [target.host, "check remote handoff tools"],
        status: output.status,
        stderr: output.stderrText
      )
    }
  }

  static func stagingScript(
    origin: String,
    state: RemoteHandoffStateFingerprint,
    manifestSHA256: String,
    archiveSHA256: String,
    bundleSHA256: String?,
    transferDirectory: String,
    stagingDirectory: String,
    ownershipToken: String
  ) -> String {
    let transferRoot = (transferDirectory as NSString).deletingLastPathComponent
    let bundleCommands =
      bundleSHA256.map { hash in
        """
        verify_file "$transfer/commits.bundle" \(POSIXShell.quote(hash))
        git -C "$staging" bundle verify "$transfer/commits.bundle" >/dev/null
        git -C "$staging" bundle unbundle "$transfer/commits.bundle" >/dev/null
        """
      } ?? "test ! -e \"$transfer/commits.bundle\""
    return """
      set -eu
      transfer=\(POSIXShell.quote(transferDirectory))
      staging=\(POSIXShell.quote(stagingDirectory))
      token=\(POSIXShell.quote(ownershipToken))
      cleanup=1
      cleanup_handoff() {
        status=$?
        trap - EXIT HUP INT TERM
        if [ "$cleanup" -eq 1 ]; then
          if [ -f "$transfer/feather-owner" ] && [ "$(cat -- "$transfer/feather-owner")" = "$token" ]; then
            rm -rf -- "$transfer" "$staging"
          elif [ -f "$staging/.git/feather-handoff/staged" ] && [ "$(cat -- "$staging/.git/feather-handoff/staged")" = "$token" ]; then
            rm -rf -- "$staging"
          fi
        fi
        exit "$status"
      }
      trap cleanup_handoff EXIT HUP INT TERM
      command -v git >/dev/null
      command -v tar >/dev/null
      command -v base64 >/dev/null
      command -v awk >/dev/null
      command -v readlink >/dev/null
      command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null
      \(sha256ShellFunctions)
      verify_file() {
        test -f "$1"
        test "$(sha256_file "$1")" = "$2"
      }
      test ! -e "$transfer"
      test ! -e "$staging"
      umask 077
      mkdir -p -- \(POSIXShell.quote(transferRoot))
      mkdir -- "$transfer"
      printf %s "$token" > "$transfer/feather-owner"
      mkdir -- "$staging"
      cat > "$transfer/payload.tar"
      verify_file "$transfer/payload.tar" \(POSIXShell.quote(archiveSHA256))
      tar -xf "$transfer/payload.tar" -C "$transfer"
      rm -f -- "$transfer/payload.tar"
      verify_file "$transfer/manifest.json" \(POSIXShell.quote(manifestSHA256))
      verify_file "$transfer/status.snapshot" \(POSIXShell.quote(state.statusSHA256))
      verify_file "$transfer/index.patch" \(POSIXShell.quote(state.indexPatchSHA256))
      verify_file "$transfer/worktree.patch" \(POSIXShell.quote(state.worktreePatchSHA256))
      verify_file "$transfer/untracked.paths" \(POSIXShell.quote(state.untrackedPathsSHA256))
      verify_file "$transfer/untracked.entries" \(POSIXShell.quote(state.untrackedEntriesSHA256))
      test -d "$transfer/untracked"
      GIT_LFS_SKIP_SMUDGE=1 git clone --no-checkout -- \(POSIXShell.quote(origin)) "$staging"
      git -C "$staging" cat-file -e \(POSIXShell.quote(state.baseCommit + "^{commit}"))
      \(bundleCommands)
      git -C "$staging" cat-file -e \(POSIXShell.quote(state.headCommit + "^{commit}"))
      git -C "$staging" checkout -B \(POSIXShell.quote(state.branch)) \(POSIXShell.quote(state.headCommit))
      if [ -s "$transfer/index.patch" ]; then
        git -C "$staging" apply --binary --index --whitespace=nowarn "$transfer/index.patch"
      fi
      if [ -s "$transfer/worktree.patch" ]; then
        git -C "$staging" apply --binary --whitespace=nowarn "$transfer/worktree.patch"
      fi
      tar -C "$transfer/untracked" -cf - . | tar -C "$staging" -xf -
      test "$(git -C "$staging" rev-parse --verify HEAD^{commit})" = \(POSIXShell.quote(state.headCommit))
      git -C "$staging" -c diff.mnemonicPrefix=false -c diff.noprefix=false diff --binary --full-index --no-color --no-ext-diff --no-textconv --no-renames --src-prefix=a/ --dst-prefix=b/ --cached > "$transfer/remote-index.patch"
      git -C "$staging" -c diff.mnemonicPrefix=false -c diff.noprefix=false diff --binary --full-index --no-color --no-ext-diff --no-textconv --no-renames --src-prefix=a/ --dst-prefix=b/ > "$transfer/remote-worktree.patch"
      git -C "$staging" status --porcelain=v1 -z --untracked-files=all --no-renames > "$transfer/remote-status.snapshot"
      git -C "$staging" ls-files --others --exclude-standard -z > "$transfer/remote-untracked.paths"
      verify_file "$transfer/remote-index.patch" \(POSIXShell.quote(state.indexPatchSHA256))
      verify_file "$transfer/remote-worktree.patch" \(POSIXShell.quote(state.worktreePatchSHA256))
      verify_file "$transfer/remote-status.snapshot" \(POSIXShell.quote(state.statusSHA256))
      verify_file "$transfer/remote-untracked.paths" \(POSIXShell.quote(state.untrackedPathsSHA256))
      tab=$(printf '\t')
      entry_count=0
      while IFS="$tab" read -r kind executable expected_size expected_hash encoded_path; do
        test -n "$encoded_path"
        path=$(printf %s "$encoded_path" | base64 -d)
        case "/$path/" in
          *"/../"*|*"/./"*|*"/.git/"*) exit 46 ;;
        esac
        target="$staging/$path"
        if [ "$kind" = f ]; then
          test -f "$target"
          test ! -L "$target"
          actual_size=$(wc -c < "$target" | tr -d ' ')
          test "$actual_size" -eq "$expected_size"
          test "$(sha256_file "$target")" = "$expected_hash"
          if [ "$executable" = 1 ]; then test -x "$target"; else test ! -x "$target"; fi
        elif [ "$kind" = l ]; then
          test -L "$target"
          link_target=$(readlink "$target")
          actual_size=$(printf %s "$link_target" | wc -c | tr -d ' ')
          test "$actual_size" -eq "$expected_size"
          test "$(printf %s "$link_target" | sha256_stdin)" = "$expected_hash"
        else
          exit 46
        fi
        entry_count=$((entry_count + 1))
      done < "$transfer/untracked.entries"
      test "$entry_count" -eq \(state.untrackedFileCount)
      mkdir -p -- "$staging/.git/feather-handoff"
      cp -- "$transfer/manifest.json" "$staging/.git/feather-handoff/manifest.json"
      cp -- "$transfer/untracked.paths" "$staging/.git/feather-handoff/untracked.paths"
      cp -- "$transfer/untracked.entries" "$staging/.git/feather-handoff/untracked.entries"
      printf %s \(POSIXShell.quote(ownershipToken)) > "$staging/.git/feather-handoff/staged"
      rm -rf -- "$transfer"
      cleanup=0
      trap - EXIT HUP INT TERM
      printf 'staged:%s\n' "$token"
      """
  }

  static func finalizationScript(
    destination: String,
    controlRoot: String,
    configPath: String,
    markerPath: String,
    stagingDirectory: String,
    ownershipToken: String,
    workspaceSessionID: String,
    tmuxSocketName: String = "feather"
  ) -> String {
    let parent = (destination as NSString).deletingLastPathComponent
    let markerDirectory = (markerPath as NSString).deletingLastPathComponent
    return """
      set -eu
      staging=\(POSIXShell.quote(stagingDirectory))
      destination=\(POSIXShell.quote(destination))
      marker=\(POSIXShell.quote(markerPath))
      checkout_marker="$destination/.git/feather-owner"
      token=\(POSIXShell.quote(ownershipToken))
      session=\(POSIXShell.quote(workspaceSessionID))
      cleanup=1
      moved=0
      session_created=0
      cleanup_handoff() {
        status=$?
        trap - EXIT HUP INT TERM
        if [ "$session_created" -eq 1 ]; then
          tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) kill-session -t "$session" >/dev/null 2>&1 || true
        fi
        if [ -f "$marker" ] && [ "$(cat -- "$marker")" = "$token" ]; then rm -f -- "$marker"; fi
        if [ -f "$checkout_marker" ] && [ "$(cat -- "$checkout_marker")" = "$token" ]; then rm -f -- "$checkout_marker"; fi
        if [ "$moved" -eq 1 ]; then
          if [ -f "$destination/.git/feather-handoff/staged" ] && [ "$(cat -- "$destination/.git/feather-handoff/staged")" = "$token" ]; then rm -rf -- "$destination"; fi
        elif [ -f "$staging/.git/feather-handoff/staged" ] && [ "$(cat -- "$staging/.git/feather-handoff/staged")" = "$token" ]; then
          rm -rf -- "$staging"
        fi
        exit "$status"
      }
      trap cleanup_handoff EXIT HUP INT TERM
      command -v tmux >/dev/null
      command -v base64 >/dev/null
      test -d "$staging/.git"
      test -f "$staging/.git/feather-handoff/staged"
      test "$(cat -- "$staging/.git/feather-handoff/staged")" = \(POSIXShell.quote(ownershipToken))
      test ! -e "$destination"
      test ! -e "$marker"
      ! tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) has-session -t "$session" >/dev/null 2>&1
      umask 077
      mkdir -p -- \(POSIXShell.quote(parent)) \(POSIXShell.quote(controlRoot)) \(POSIXShell.quote(markerDirectory))
      printf %s \(POSIXShell.quote(Data(remoteTmuxConfiguration.utf8).base64EncodedString())) | base64 -d > \(POSIXShell.quote(configPath))
      mv -- "$staging" "$destination"
      test -f "$destination/.git/feather-handoff/staged"
      test "$(cat -- "$destination/.git/feather-handoff/staged")" = "$token"
      moved=1
      printf %s \(POSIXShell.quote(ownershipToken)) > "$marker"
      printf %s \(POSIXShell.quote(ownershipToken)) > "$checkout_marker"
      test "$(cat -- "$marker")" = \(POSIXShell.quote(ownershipToken))
      test "$(cat -- "$checkout_marker")" = \(POSIXShell.quote(ownershipToken))
      session_created=1
      tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) new-session -d -s "$session" -c "$destination"
      cleanup=0
      trap - EXIT HUP INT TERM
      printf 'active:%s\n' \(POSIXShell.quote(ownershipToken))
      """
  }

  static func cleanupTransferScript(
    transferDirectory: String,
    stagingDirectory: String,
    ownershipToken: String
  ) -> String {
    """
    set -eu
    transfer=\(POSIXShell.quote(transferDirectory))
    staging=\(POSIXShell.quote(stagingDirectory))
    token=\(POSIXShell.quote(ownershipToken))
    if [ -f "$transfer/feather-owner" ] && [ "$(cat -- "$transfer/feather-owner")" = "$token" ]; then
      rm -rf -- "$transfer" "$staging"
    elif [ -f "$staging/.git/feather-handoff/staged" ] && [ "$(cat -- "$staging/.git/feather-handoff/staged")" = "$token" ]; then
      rm -rf -- "$staging"
    fi
    test ! -e "$transfer"
    test ! -e "$staging"
    """
  }

  static func rollbackScript(
    destination: String,
    configPath: String,
    markerPath: String,
    ownershipToken: String,
    workspaceSessionID: String,
    tmuxSocketName: String = "feather"
  ) -> String {
    let checkoutMarker = destination + "/.git/feather-owner"
    return """
      set -eu
      destination=\(POSIXShell.quote(destination))
      marker=\(POSIXShell.quote(markerPath))
      checkout_marker=\(POSIXShell.quote(checkoutMarker))
      token=\(POSIXShell.quote(ownershipToken))
      session=\(POSIXShell.quote(workspaceSessionID))
      owns_destination=0
      owns_marker=0
      if [ -f "$destination/.git/feather-handoff/staged" ] && [ "$(cat -- "$destination/.git/feather-handoff/staged")" = "$token" ]; then
        owns_destination=1
      fi
      if [ -f "$marker" ] && [ "$(cat -- "$marker")" = "$token" ]; then
        owns_marker=1
      fi
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        test "$owns_destination" -eq 1
        if [ -e "$marker" ]; then test "$(cat -- "$marker")" = "$token"; fi
        if [ -e "$checkout_marker" ]; then test "$(cat -- "$checkout_marker")" = "$token"; fi
      fi
      if tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) has-session -t "$session" >/dev/null 2>&1; then
        [ "$owns_destination" -eq 1 ] || [ "$owns_marker" -eq 1 ]
        tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) kill-session -t "$session"
      fi
      if [ "$owns_destination" -eq 1 ]; then
        rm -f -- "$marker" "$checkout_marker"
        rm -rf -- "$destination"
      elif [ "$owns_marker" -eq 1 ]; then
        rm -f -- "$marker"
      fi
      test ! -e "$destination"
      test ! -e "$marker"
      ! tmux -L \(POSIXShell.quote(tmuxSocketName)) -f \(POSIXShell.quote(configPath)) has-session -t "$session" >/dev/null 2>&1
      """
  }

  static func ownershipCheckScript(_ workspace: RemoteWorkspaceRecord) -> String {
    let directory = POSIXShell.quote(workspace.remote.workingDirectory)
    guard let ownership = workspace.ownership else {
      return "test -d \(directory) || exit 42"
    }
    let checkoutMarker = workspace.remote.workingDirectory + "/.git/feather-owner"
    let manifestCheck: String
    if let handoff = workspace.handoff, let expectedHash = manifestSHA256(handoff) {
      let manifestPath = workspace.remote.workingDirectory + "/.git/feather-handoff/manifest.json"
      manifestCheck = """
        command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null || exit 42
        \(sha256ShellFunctions)
        test -f \(POSIXShell.quote(manifestPath)) || exit 42
        test "$(sha256_file \(POSIXShell.quote(manifestPath)))" = \(POSIXShell.quote(expectedHash)) || exit 42
        """
    } else if workspace.handoff == nil {
      manifestCheck = ""
    } else {
      manifestCheck = "exit 42"
    }
    return """
      test -d \(directory) || exit 42
      test -f \(POSIXShell.quote(ownership.markerPath)) || exit 42
      test "$(cat -- \(POSIXShell.quote(ownership.markerPath)))" = \(POSIXShell.quote(ownership.token)) || exit 42
      test -f \(POSIXShell.quote(checkoutMarker)) || exit 42
      test "$(cat -- \(POSIXShell.quote(checkoutMarker)))" = \(POSIXShell.quote(ownership.token)) || exit 42
      \(manifestCheck)
      """
  }

  static func manifestSHA256(_ manifest: RemoteHandoffManifest) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(manifest) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func cleanupRemoteTransfer(
    target: SSHRemoteTarget,
    transferDirectory: String,
    stagingDirectory: String,
    ownershipToken: String
  ) async -> Bool {
    guard
      let output = try? await runner.run(
        sshExecutable,
        arguments: Self.noninteractiveSSHArguments(target: target) + [
          target.host,
          Self.cleanupTransferScript(
            transferDirectory: transferDirectory,
            stagingDirectory: stagingDirectory,
            ownershipToken: ownershipToken
          ),
        ],
        maximumOutputBytes: 128 * 1_024,
        timeout: 30
      )
    else { return false }
    return output.status == 0
  }

  private func rollbackRemoteWorkspace(
    target: SSHRemoteTarget,
    destination: String,
    configPath: String,
    markerPath: String,
    ownershipToken: String,
    workspaceSessionID: String
  ) async -> Bool {
    guard
      let output = try? await runner.run(
        sshExecutable,
        arguments: Self.noninteractiveSSHArguments(target: target) + [
          target.host,
          Self.rollbackScript(
            destination: destination,
            configPath: configPath,
            markerPath: markerPath,
            ownershipToken: ownershipToken,
            workspaceSessionID: workspaceSessionID,
            tmuxSocketName: tmuxSocketName
          ),
        ],
        maximumOutputBytes: 128 * 1_024,
        timeout: 30
      )
    else { return false }
    return output.status == 0
  }

  static func noninteractiveSSHArguments(target: SSHRemoteTarget) -> [String] {
    [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ForwardAgent=no",
      "-p", String(target.port), "--",
    ]
  }

  private static func hasReceipt(_ receipt: String, in output: String) -> Bool {
    output.split(whereSeparator: \.isNewline).last.map(String.init) == receipt
  }

  private static func slug(_ value: String) -> String {
    let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar)
        ? Character(String(scalar)) : "-"
    }
    let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return value.isEmpty ? "repository" : String(value.prefix(60))
  }

  static func workspaceSessionID(_ workspaceID: UUID) -> String {
    "feather-workspace-"
      + workspaceID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
  }

  private static let sha256ShellFunctions = """
    sha256_file() {
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
      else
        shasum -a 256 "$1" | awk '{print $1}'
      fi
    }
    sha256_stdin() {
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
      else
        shasum -a 256 | awk '{print $1}'
      fi
    }
    """

  private static let remoteTmuxConfiguration = """
    # Managed by Feather. Personal tmux configuration is intentionally not loaded.
    set -g default-terminal "tmux-256color"
    set -g focus-events on
    set -g mouse on
    set -g status off
    set -g history-limit 10000
    set -g set-clipboard on
    set -g allow-passthrough on
    set -g detach-on-destroy on
    set -g pane-border-style "fg=colour8"
    set -g pane-active-border-style "fg=colour8"

    """
}
