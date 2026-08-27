import Combine
import Sparkle
import SwiftUI

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
  @Published private(set) var canCheckForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .receive(on: RunLoop.main)
      .assign(to: &$canCheckForUpdates)
  }
}

struct CheckForUpdatesView: View {
  @StateObject private var viewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    self.updater = updater
    _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
  }

  var body: some View {
    Button("Check for Updates…", action: updater.checkForUpdates)
      .disabled(!viewModel.canCheckForUpdates)
  }
}
