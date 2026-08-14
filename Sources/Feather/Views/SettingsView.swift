import FeatherCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var draftProfileID: UUID?
  @State private var remoteName: String
  @State private var remoteHost: String
  @State private var remotePort: Int
  @State private var remoteRoot: String

  init(model: AppModel) {
    self.model = model
    let profile = model.selectedRemoteProfile
    _draftProfileID = State(initialValue: profile?.id)
    _remoteName = State(initialValue: profile?.name ?? "")
    _remoteHost = State(initialValue: profile?.target.host ?? "")
    _remotePort = State(initialValue: profile?.target.port ?? 22)
    _remoteRoot = State(initialValue: profile?.target.rootPath ?? "")
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

      Section("SSH Profiles") {
        Picker("Profile", selection: $draftProfileID) {
          Text("New Profile").tag(nil as UUID?)
          ForEach(model.remoteProfiles) { profile in
            Text(profile.name).tag(profile.id as UUID?)
          }
        }
        .onChange(of: draftProfileID) { _, id in
          model.selectRemoteProfile(id)
          loadProfile(id)
        }

        TextField("Profile name", text: $remoteName)
        TextField("SSH host or alias", text: $remoteHost)
        HStack {
          TextField("Port", value: $remotePort, format: .number)
            .frame(width: 90)
          TextField("Absolute remote root", text: $remoteRoot)
        }
        HStack {
          Button(draftProfileID == nil ? "Add Profile" : "Save Changes") {
            model.saveRemoteProfile(
              id: draftProfileID,
              name: remoteName,
              target: draftRemoteTarget
            )
            draftProfileID = model.selectedRemoteProfileID
          }
          .disabled(!hasRemoteDraft || model.isBusy)

          Button("Test Connection") { model.testRemoteTarget(draftRemoteTarget) }
            .disabled(!hasRemoteDraft || model.isBusy)

          Button("New") { beginNewProfile() }
            .disabled(draftProfileID == nil)

          if let draftProfileID {
            Button("Delete", role: .destructive) {
              model.deleteRemoteProfile(draftProfileID)
              if !model.remoteProfiles.contains(where: { $0.id == draftProfileID }) {
                beginNewProfile()
              }
            }
            .disabled(model.remoteProfileIsInUse(draftProfileID) || model.isBusy)
          }

          if model.isBusy { ProgressView().controlSize(.small) }
        }
        Text(
          "Use an OpenSSH alias when possible. The host must already have Git, tmux, repository "
            + "credentials, and your agent CLI authentication. Feather stores only the profile "
            + "name, host, port, and remote root—never passwords, private keys, cloud tokens, or "
            + "agent credentials."
        )
        .font(.feather(size: 11))
        .foregroundStyle(.secondary)
      }
    }
    .font(.feather(size: 13))
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 600, height: 680)
  }

  private var hasRemoteDraft: Bool {
    !remoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var draftRemoteTarget: SSHRemoteTarget {
    SSHRemoteTarget(host: remoteHost, port: remotePort, rootPath: remoteRoot)
  }

  private func loadProfile(_ id: UUID?) {
    guard let profile = model.remoteProfiles.first(where: { $0.id == id }) else {
      remoteName = ""
      remoteHost = ""
      remotePort = 22
      remoteRoot = ""
      return
    }
    remoteName = profile.name
    remoteHost = profile.target.host
    remotePort = profile.target.port
    remoteRoot = profile.target.rootPath
  }

  private func beginNewProfile() {
    draftProfileID = nil
    model.selectRemoteProfile(nil)
    loadProfile(nil)
  }
}
