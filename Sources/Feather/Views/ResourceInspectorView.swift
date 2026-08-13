import FeatherCore
import Foundation
import SwiftUI

@MainActor
private final class ResourceInspectorModel: ObservableObject {
  @Published private(set) var snapshot: ProcessResourceSnapshot?
  @Published private(set) var peakResidentKiB = 0
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?

  private let service = ProcessResourceService()
  private var samplingTask: Task<Void, Never>?

  func start() {
    guard samplingTask == nil else { return }
    samplingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await sample()
        do {
          try await Task.sleep(for: .seconds(2))
        } catch {
          break
        }
      }
    }
  }

  func refresh() {
    samplingTask?.cancel()
    samplingTask = nil
    isLoading = false
    start()
  }

  func cancel() {
    samplingTask?.cancel()
    samplingTask = nil
    snapshot = nil
    peakResidentKiB = 0
    isLoading = false
  }

  private func sample() async {
    guard !isLoading else { return }
    isLoading = true
    error = nil
    do {
      let value = try await service.snapshot(
        applicationPID: ProcessInfo.processInfo.processIdentifier)
      guard !Task.isCancelled else { return }
      snapshot = value
      peakResidentKiB = max(peakResidentKiB, value.residentKiB)
    } catch is CancellationError {
      return
    } catch {
      self.error = error.localizedDescription
    }
    isLoading = false
  }
}

struct ResourceInspectorView: View {
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ResourceInspectorModel()

  private var palette: FeatherPalette { FeatherPalette(colorScheme: colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 7) {
        Image(systemName: "gauge.with.needle")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(palette.secondaryText)
        Text("On-demand usage")
          .font(.feather(size: 12, weight: .semibold))
          .foregroundStyle(palette.primaryText)
        Spacer(minLength: 0)
        if model.isLoading { ProgressView().controlSize(.mini) }
        Button(action: model.refresh) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(HoverButtonStyle())
        .disabled(model.isLoading)
        .help("Sample Now")
      }
      .padding(.horizontal, 10)
      .frame(height: 35)
      .overlay(alignment: .bottom) {
        Rectangle().fill(palette.border.opacity(0.65)).frame(height: 1)
      }

      if let snapshot = model.snapshot {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
              metric("CPU", value: cpu(snapshot.cpuPercent))
              metric("RSS", value: bytes(snapshot.residentKiB))
            }
            HStack(spacing: 5) {
              Text("Peak this view")
              Spacer(minLength: 0)
              Text(bytes(model.peakResidentKiB))
                .foregroundStyle(palette.primaryText)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.mutedText)

            Rectangle().fill(palette.border.opacity(0.6)).frame(height: 1)

            ForEach(snapshot.summaries) { summary in
              resourceRow(summary)
            }

            Text(
              "Samples every 2 seconds only while this tab is visible. Includes Feather and its private tmux process tree."
            )
            .font(.feather(size: 9))
            .foregroundStyle(palette.mutedText)
            .fixedSize(horizontal: false, vertical: true)
          }
          .padding(10)
        }
      } else if let error = model.error {
        VStack(spacing: 9) {
          Text(error)
            .multilineTextAlignment(.center)
          Button("Try Again", action: model.refresh)
            .controlSize(.small)
        }
        .font(.feather(size: 11))
        .foregroundStyle(palette.secondaryText)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task { model.start() }
    .onDisappear { model.cancel() }
  }

  private func metric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.feather(size: 9, weight: .semibold))
        .foregroundStyle(palette.mutedText)
      Text(value)
        .font(.system(size: 16, weight: .medium, design: .monospaced))
        .foregroundStyle(palette.primaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.selection.opacity(0.62))
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private func resourceRow(_ summary: ProcessResourceSummary) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol(summary.kind))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(palette.mutedText)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(summary.kind.rawValue)
          .font(.feather(size: 11, weight: .medium))
          .foregroundStyle(palette.primaryText)
        Text("\(summary.processCount) \(summary.processCount == 1 ? "process" : "processes")")
          .font(.feather(size: 9))
          .foregroundStyle(palette.mutedText)
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: 2) {
        Text(bytes(summary.residentKiB))
        Text(cpu(summary.cpuPercent))
      }
      .font(.system(size: 9, weight: .medium, design: .monospaced))
      .foregroundStyle(palette.secondaryText)
    }
    .frame(minHeight: 31)
  }

  private func bytes(_ residentKiB: Int) -> String {
    ByteCountFormatter.string(
      fromByteCount: Int64(residentKiB) * 1_024,
      countStyle: .memory
    )
  }

  private func cpu(_ value: Double) -> String { String(format: "%.1f%%", value) }

  private func symbol(_ kind: ProcessResourceKind) -> String {
    switch kind {
    case .feather: "app"
    case .tmux: "rectangle.split.2x1"
    case .claude: "sparkles"
    case .codex: "terminal"
    case .child: "gearshape.2"
    }
  }
}
