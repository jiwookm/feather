import Darwin
import Foundation

enum FeatherBuildVariant: String, Equatable, Sendable {
  case development
  case production
}

struct FeatherRuntimeIdentity: Equatable, Sendable {
  static let buildVariantInfoKey = "FeatherBuildVariant"

  let variant: FeatherBuildVariant
  let applicationSupportDirectoryName: String
  let legacyApplicationSupportDirectoryName: String?
  let localTmuxSocketName: String
  let remoteControlDirectoryName: String
  let remoteTmuxSocketName: String

  init(variant: FeatherBuildVariant, userID: uid_t) {
    self.variant = variant
    switch variant {
    case .development:
      applicationSupportDirectoryName = "Feather Dev"
      legacyApplicationSupportDirectoryName = nil
      localTmuxSocketName = "feather-dev-\(userID)"
      remoteControlDirectoryName = ".feather-dev"
      remoteTmuxSocketName = "feather-dev"
    case .production:
      applicationSupportDirectoryName = "Feather"
      legacyApplicationSupportDirectoryName = "Barnacle"
      // Keep the legacy socket so installed upgrades reattach existing sessions.
      localTmuxSocketName = "barnacle-\(userID)"
      remoteControlDirectoryName = ".feather"
      remoteTmuxSocketName = "feather"
    }
  }

  static var current: FeatherRuntimeIdentity {
    resolve(infoDictionary: Bundle.main.infoDictionary, userID: getuid())
  }

  static func resolve(
    infoDictionary: [String: Any]?,
    userID: uid_t
  ) -> FeatherRuntimeIdentity {
    let rawVariant = infoDictionary?[buildVariantInfoKey] as? String
    let variant = FeatherBuildVariant(rawValue: rawVariant ?? "") ?? .development
    return FeatherRuntimeIdentity(variant: variant, userID: userID)
  }
}
