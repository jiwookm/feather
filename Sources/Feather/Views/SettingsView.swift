import FeatherCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel

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
    }
    .font(.feather(size: 13))
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 520, height: 430)
  }
}
