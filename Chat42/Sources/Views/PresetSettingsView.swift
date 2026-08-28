import SwiftUI

/// Manages saved prompt presets.
///
/// A preset bundles instructions with the backend, model, and temperature that suit
/// them, so recurring work — reviewing code, translating, writing commit messages —
/// starts configured instead of being retyped.
struct PresetSettingsView: View {
  @Environment(AppState.self) private var state

  @State private var selection: UUID?
  @State private var draft: PromptPreset?

  var body: some View {
    Form {
      Section(String(localized: "settings.presets.section")) {
        Text("settings.presets.description")
          .font(.callout)
          .foregroundStyle(.secondary)

        if state.presets.isEmpty {
          Label(String(localized: "settings.presets.empty"), systemImage: "tray")
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          ForEach(state.presets) { preset in
            Button {
              selection = preset.id
              draft = preset
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(preset.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                  Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if selection == preset.id {
                  Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }

        HStack {
          Button {
            let preset = PromptPreset(
              name: String(localized: "preset.new.name"),
              systemPrompt: "")
            selection = preset.id
            draft = preset
          } label: {
            Label(String(localized: "settings.presets.add"), systemImage: "plus")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)

          if let selection, let preset = state.preset(id: selection) {
            Button(role: .destructive) {
              state.deletePreset(preset)
              self.selection = nil
              draft = nil
            } label: {
              Label(String(localized: "settings.presets.delete"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
      }

      if draft != nil {
        editor
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var editor: some View {
    // The binding is safe: this branch only renders when `draft` is non-nil.
    let binding = Binding<PromptPreset>(
      get: { draft ?? PromptPreset(name: "", systemPrompt: "") },
      set: { draft = $0 }
    )

    Section(String(localized: "settings.presets.edit")) {
      LabeledContent(String(localized: "settings.presets.name")) {
        TextField("", text: binding.name)
          .textFieldStyle(.roundedBorder)
          .frame(width: 240)
          .accessibilityLabel(Text("settings.presets.name"))
      }

      LabeledContent(String(localized: "settings.presets.prompt")) {
        TextEditor(text: binding.systemPrompt)
          .font(.callout)
          .frame(width: 280, height: 90)
          .scrollContentBackground(.hidden)
          .padding(6)
          .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel(Text("settings.presets.prompt"))
      }

      // "Use current" keeps a preset that is only about tone from also pinning a
      // model it has no opinion about.
      LabeledContent(String(localized: "settings.presets.backend")) {
        Picker("", selection: binding.backend) {
          Text("settings.presets.use_current").tag(AIBackend?.none)
          ForEach(AIBackend.allCases, id: \.self) { backend in
            Text(backend.rawValue).tag(AIBackend?.some(backend))
          }
        }
        .labelsHidden()
        .frame(width: 160)
        .accessibilityLabel(Text("settings.presets.backend"))
      }

      LabeledContent(String(localized: "settings.presets.model")) {
        TextField(
          String(localized: "settings.presets.model.placeholder"),
          text: Binding(
            get: { binding.wrappedValue.modelName ?? "" },
            set: { binding.wrappedValue.modelName = $0.isEmpty ? nil : $0 }
          )
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 240)
        .accessibilityLabel(Text("settings.presets.model"))
      }

      LabeledContent(String(localized: "settings.presets.temperature")) {
        HStack(spacing: 8) {
          Toggle(
            String(localized: "settings.presets.pin_temperature"),
            isOn: Binding(
              get: { binding.wrappedValue.temperature != nil },
              set: { binding.wrappedValue.temperature = $0 ? state.temperature : nil }
            )
          )
          .labelsHidden()

          if let temperature = binding.wrappedValue.temperature {
            Slider(
              value: Binding(
                get: { temperature },
                set: { binding.wrappedValue.temperature = $0 }
              ), in: 0...2, step: 0.05
            )
            .frame(width: 120)
            .accessibilityLabel(Text("settings.presets.temperature"))
            Text(String(format: "%.2f", temperature))
              .font(.caption)
              .monospacedDigit()
              .frame(width: 34)
          }
        }
      }

      HStack {
        Spacer()
        Button(String(localized: "settings.presets.cancel")) {
          draft = nil
          selection = nil
        }
        .buttonStyle(.bordered)
        Button(String(localized: "settings.presets.save")) {
          if let draft { state.savePreset(draft) }
          draft = nil
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          binding.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty
            || binding.wrappedValue.systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty
        )
      }
    }
  }
}
