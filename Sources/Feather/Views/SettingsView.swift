import FeatherCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var remoteHost: String
  @State private var remotePort: Int
  @State private var remoteRoot: String

  init(model: AppModel) {
    self.model = model
    _remoteHost = State(initialValue: model.remoteTarget.host)
    _remotePort = State(initialValue: model.remoteTarget.port)
    _remoteRoot = State(initialValue: model.remoteTarget.rootPath)
  }

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $model.appearance) {
          ForEach(AppearancePreference.allCases) { appearance in
            Text(appearance.title).tag(appearance)
          }
        }
        .pickerStyle(.segmented)
        Text("System follows macOS. Light and Dark are Feather's only fixed palettes.")
          .font(.feather(size: 11))
          .foregroundStyle(.secondary)
      }

      Section("Keybindings") {
        LabeledContent("Next terminal tab", value: "⌃⇥")
        LabeledContent("Previous terminal tab", value: "⌃⇧⇥")
        LabeledContent("Split right", value: "⌘D")
        LabeledContent("Split down", value: "⌘⇧D")
        LabeledContent("Close active file, pane, or tab", value: "⌘W")
        LabeledContent("Save open file", value: "⌘⇧S")
        LabeledContent("Toggle project sidebar", value: "⌘S")
        LabeledContent("Toggle inspector", value: "⌘E")
        LabeledContent("Search repository", value: "⌘⇧F")
      }

      Section("Terminals") {
        LabeledContent("Persistence", value: "Private tmux server")
        LabeledContent("tmux", value: model.tmuxSpec?.executableURL.path ?? "Not installed")
        Text("Feather does not read your personal tmux or Ghostty configuration.")
          .font(.feather(size: 11))
          .foregroundStyle(.secondary)
      }

      Section("Worktrees") {
        LabeledContent("New checkouts", value: model.worktreesRoot.path)
      }

      Section("Remote Handoff") {
        TextField("SSH host or alias", text: $remoteHost)
        HStack {
          TextField("Port", value: $remotePort, format: .number)
            .frame(width: 90)
          TextField("Absolute remote root", text: $remoteRoot)
        }
        HStack {
          Button("Save") { model.saveRemoteTarget(draftRemoteTarget) }
            .disabled(!hasRemoteDraft || model.isBusy)
          Button("Test Connection") { model.testRemoteTarget(draftRemoteTarget) }
            .disabled(!hasRemoteDraft || model.isBusy)
          if model.isBusy { ProgressView().controlSize(.small) }
        }
        Text(
          "Use an OpenSSH alias when possible. The host must already have Git, tmux, repository "
            + "credentials, and your agent CLI authentication. Feather does not store passwords "
            + "or enable SSH agent forwarding."
        )
        .font(.feather(size: 11))
        .foregroundStyle(.secondary)
      }
    }
    .font(.feather(size: 13))
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 560, height: 600)
  }

  private var hasRemoteDraft: Bool {
    !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var draftRemoteTarget: SSHRemoteTarget {
    SSHRemoteTarget(host: remoteHost, port: remotePort, rootPath: remoteRoot)
  }
}
