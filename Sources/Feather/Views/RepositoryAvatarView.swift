import AppKit
import FeatherCore
import Foundation
import SwiftUI

@MainActor
final class RepositoryAvatarStore: ObservableObject {
  @Published private var images: [String: NSImage] = [:]
  private var failures: Set<String> = []
  private var tasks: [String: Task<Void, Never>] = [:]
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(
      memoryCapacity: 512 * 1_024,
      diskCapacity: 8 * 1_024 * 1_024,
      directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Feather/RepositoryAvatars", isDirectory: true)
    )
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    session = URLSession(configuration: configuration)
  }

  func image(for repository: RepositoryRecord) -> NSImage? {
    guard let identity = GitHubRepositoryIdentity(remoteURL: repository.remoteURL) else {
      return nil
    }
    return images[identity.owner.lowercased()]
  }

  func load(_ repository: RepositoryRecord) {
    guard let identity = GitHubRepositoryIdentity(remoteURL: repository.remoteURL) else { return }
    let key = identity.owner.lowercased()
    guard images[key] == nil, !failures.contains(key), tasks[key] == nil else { return }
    tasks[key] = Task { [weak self] in
      guard let self else { return }
      do {
        var request = URLRequest(url: identity.avatarURL)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard !Task.isCancelled,
          data.count <= 256 * 1_024,
          let response = response as? HTTPURLResponse,
          200..<300 ~= response.statusCode,
          response.mimeType?.hasPrefix("image/") == true,
          let image = NSImage(data: data)
        else {
          failures.insert(key)
          tasks[key] = nil
          return
        }
        images[key] = image
      } catch is CancellationError {
        return
      } catch {
        failures.insert(key)
      }
      tasks[key] = nil
    }
  }

  func cancel() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll(keepingCapacity: true)
  }
}

struct RepositoryAvatarView: View {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var store: RepositoryAvatarStore
  let repository: RepositoryRecord

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    Group {
      if let avatar = store.image(for: repository) {
        Image(nsImage: avatar)
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(palette.selection)
          Image(systemName: "shippingbox.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.secondaryText)
        }
      }
    }
    .frame(width: 25, height: 25)
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .stroke(palette.border.opacity(0.65), lineWidth: 0.5)
    }
    .task(id: repository.remoteURL) {
      store.load(repository)
    }
  }
}
