import Testing

@testable import Feather

struct RuntimeIdentityTests {
  @Test
  func unmarkedExecutablesUseTheIsolatedDevelopmentIdentity() {
    let identity = FeatherRuntimeIdentity.resolve(infoDictionary: nil, userID: 501)

    #expect(identity.variant == .development)
    #expect(identity.applicationSupportDirectoryName == "Feather Dev")
    #expect(identity.legacyApplicationSupportDirectoryName == nil)
    #expect(identity.localTmuxSocketName == "feather-dev-501")
    #expect(identity.remoteControlDirectoryName == ".feather-dev")
    #expect(identity.remoteTmuxSocketName == "feather-dev")
  }

  @Test
  func productionMarkerPreservesExistingRuntimeIdentity() {
    let identity = FeatherRuntimeIdentity.resolve(
      infoDictionary: [FeatherRuntimeIdentity.buildVariantInfoKey: "production"],
      userID: 502
    )

    #expect(identity.variant == .production)
    #expect(identity.applicationSupportDirectoryName == "Feather")
    #expect(identity.legacyApplicationSupportDirectoryName == "Barnacle")
    #expect(identity.localTmuxSocketName == "barnacle-502")
    #expect(identity.remoteControlDirectoryName == ".feather")
    #expect(identity.remoteTmuxSocketName == "feather")
  }

  @Test
  func unknownBuildMarkersFailClosedToDevelopment() {
    let identity = FeatherRuntimeIdentity.resolve(
      infoDictionary: [FeatherRuntimeIdentity.buildVariantInfoKey: "preview"],
      userID: 503
    )

    #expect(identity.variant == .development)
  }
}
