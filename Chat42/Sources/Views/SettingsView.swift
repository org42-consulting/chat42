import AppKit
import SwiftUI

struct SettingsView: View {
  @Environment(AppState.self) private var state
  @Environment(MLXService.self) private var mlxService

  @State private var ollamaURL: String = ""
  @State private var systemPrompt: String = ""
  @State private var temperature: Double = 0.7
  @State private var contextTokenLimit: Int = AppState.defaultContextTokenLimit
  @State private var selectedTab: SettingsTab = .general

  // Toast
  @State private var toastMessage: String = ""
  @State private var toastSuccess: Bool = true
  @State private var showToast: Bool = false
  @State private var toastDismissTask: Task<Void, Never>?

  // Ollama test
  @State private var isTestingOllama: Bool = false
  @State private var ollamaTestResult: Bool? = nil

  // Gateway
  @State private var gatewayURL: String = ""
  @State private var gatewayAPIKey: String = ""
  @State private var showAPIKey: Bool = false
  @State private var isTestingGateway: Bool = false

  enum SettingsTab: String, CaseIterable, Identifiable {
    case general, ollama, gateway, mlx, appearance

    var id: Self { self }

    var label: String {
      switch self {
      case .general: return String(localized: "settings.tab.general")
      case .ollama: return String(localized: "settings.tab.ollama")
      case .gateway: return String(localized: "settings.tab.gateway")
      case .mlx: return String(localized: "settings.tab.mlx")
      case .appearance: return String(localized: "settings.tab.appearance")
      }
    }

    var icon: String {
      switch self {
      case .general: return "gearshape"
      case .ollama: return "server.rack"
      case .gateway: return "globe"
      case .mlx: return "apple.terminal"
      case .appearance: return "paintpalette"
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      // Bound selection, not a tap gesture: without it the list highlights nothing
      // and the arrow keys do not move between panes.
      List(SettingsTab.allCases, selection: $selectedTab) { tab in
        Label(tab.label, systemImage: tab.icon)
          .tag(tab)
      }
      .navigationSplitViewColumnWidth(min: 150, ideal: 170)
    } detail: {
      Group {
        switch selectedTab {
        case .general: generalSettings
        case .ollama: ollamaSettings
        case .gateway: gatewaySettings
        case .mlx: mlxSettings
        case .appearance: appearanceSettings
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(width: 640, height: 480)
    .overlay(alignment: .bottom) {
      if showToast {
        HStack(spacing: 8) {
          Image(systemName: toastSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(toastSuccess ? .green : .red)
          Text(toastMessage)
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
      }
    }
    .animation(.easeInOut(duration: 0.25), value: showToast)
    .onAppear { loadFromState() }
    // Closing the window without pressing Done should not silently discard edits.
    .onDisappear { apply() }
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(String(localized: "settings.done")) {
          apply()
          NSApp.keyWindow?.performClose(nil)
        }
        .keyboardShortcut(.return)
      }
    }
  }

  private func loadFromState() {
    ollamaURL = state.ollamaBaseURL
    systemPrompt = state.systemPrompt
    temperature = state.temperature
    contextTokenLimit = state.contextTokenLimit
    gatewayURL = state.gatewayBaseURL
    gatewayAPIKey = KeychainHelper.load(forKey: "gatewayAPIKey") ?? ""
  }

  // MARK: - General

  private static let contextChoices = [2048, 4096, 8192, 16384, 32768, 65536, 131_072]

  private var generalSettings: some View {
    Form {
      Section(String(localized: "settings.general.section.conversation")) {
        LabeledContent(String(localized: "settings.general.system_prompt.label")) {
          VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $systemPrompt)
              .font(.callout)
              .multilineTextAlignment(.leading)
              .frame(width: 280, height: 72)
              .scrollContentBackground(.hidden)
              .padding(6)
              .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
              .accessibilityLabel(Text("settings.general.system_prompt.label"))
            Text("settings.general.system_prompt.hint")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        LabeledContent {
          HStack(spacing: 8) {
            Slider(value: $temperature, in: 0...2, step: 0.05)
              .frame(width: 160)
              .accessibilityLabel(Text("settings.general.temperature.label"))
            Text(String(format: "%.2f", temperature))
              .font(.callout)
              .monospacedDigit()
              .frame(width: 36)
          }
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("settings.general.temperature.label")
              .font(.callout)
            Text("settings.general.temperature.hint")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        LabeledContent {
          Picker("", selection: $contextTokenLimit) {
            ForEach(Self.contextChoices, id: \.self) { limit in
              Text(verbatim: "\(limit / 1024)K").tag(limit)
            }
          }
          .labelsHidden()
          .frame(width: 100)
          .accessibilityLabel(Text("settings.general.context.label"))
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("settings.general.context.label")
              .font(.callout)
            Text("settings.general.context.hint")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Gateway

  private var gatewaySettings: some View {
    Form {
      Section(String(localized: "settings.gateway.section.connection")) {
        LabeledContent(String(localized: "settings.gateway.base_url")) {
          TextField(
            String(localized: "settings.gateway.base_url.placeholder"),
            text: $gatewayURL
          )
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.leading)
          .frame(width: 240)
          .font(.callout)
          .autocorrectionDisabled()
        }

        LabeledContent(String(localized: "settings.gateway.api_key")) {
          HStack(spacing: 6) {
            apiKeyField
              .frame(width: 210)
            Button {
              showAPIKey.toggle()
            } label: {
              Image(systemName: showAPIKey ? "eye.slash" : "eye")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(
              showAPIKey
                ? String(localized: "settings.gateway.api_key.hide")
                : String(localized: "settings.gateway.api_key.show")
            )
            .accessibilityLabel(
              Text(
                showAPIKey
                  ? "settings.gateway.api_key.hide"
                  : "settings.gateway.api_key.show")
            )
          }
        }

        Text("settings.gateway.api_key.hint")
          .font(.caption)
          .foregroundStyle(.secondary)

        LabeledContent(String(localized: "settings.ollama.status.label")) {
          HStack(spacing: 10) {
            HStack(spacing: 5) {
              Circle()
                .fill(state.gatewayReachable ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
              Text(
                state.gatewayReachable
                  ? String(localized: "settings.gateway.status.connected")
                  : String(localized: "settings.gateway.status.disconnected")
              )
              .font(.callout)
              .foregroundStyle(state.gatewayReachable ? .green : .secondary)
            }
            .accessibilityElement(children: .combine)

            Button {
              isTestingGateway = true
              Task {
                await state.applyGatewaySettings(baseURL: gatewayURL, apiKey: gatewayAPIKey)
                isTestingGateway = false
                presentToast(
                  success: state.gatewayReachable,
                  message: state.gatewayReachable
                    ? String(localized: "settings.gateway.status.connected")
                    : String(localized: "settings.gateway.status.disconnected")
                )
              }
            } label: {
              HStack(spacing: 4) {
                if isTestingGateway {
                  ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
                }
                Text("settings.gateway.test_connection")
              }
            }
            .buttonStyle(.bordered)
            .disabled(isTestingGateway || gatewayURL.isEmpty)
          }
        }
      }

      Section(String(localized: "settings.gateway.section.compatible")) {
        Text("settings.gateway.compatible.desc")
          .font(.callout)
          .foregroundStyle(.secondary)

        HStack(spacing: 10) {
          ForEach(gatewayExamples, id: \.name) { example in
            Button {
              gatewayURL = example.url
            } label: {
              Label(example.name, systemImage: "link")
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(example.url)
          }
        }
      }

      if !state.gatewayModels.isEmpty {
        Section(
          String(format: String(localized: "settings.gateway.models"), state.gatewayModels.count)
        ) {
          ForEach(state.gatewayModels, id: \.id) { (model: GatewayModelInfo) in
            Button {
              state.selectedGatewayModel = model
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 5) {
                    Text(model.displayName)
                      .font(.callout)
                      .fontWeight(.medium)
                      .foregroundStyle(.primary)
                    if model.isImageGeneration {
                      Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(String(localized: "model.gateway.section.images"))
                    }
                  }
                  if let owner = model.ownedBy, !owner.isEmpty {
                    Text(owner)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                Spacer()
                if model.id == state.selectedGatewayModel?.id {
                  Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  /// Renders TextField or SecureField as a single view (avoids Group { if/else } multi-row issue in Form).
  @ViewBuilder
  private var apiKeyField: some View {
    if showAPIKey {
      TextField(
        String(localized: "settings.gateway.api_key.placeholder"),
        text: $gatewayAPIKey
      )
      .textFieldStyle(.roundedBorder)
      .font(.callout)
      .autocorrectionDisabled()
    } else {
      SecureField(
        String(localized: "settings.gateway.api_key.placeholder"),
        text: $gatewayAPIKey
      )
      .textFieldStyle(.roundedBorder)
      .font(.callout)
    }
  }

  private let gatewayExamples: [(name: String, url: String)] = [
    (name: "LiteLLM", url: "http://localhost:4000"),
    (name: "OpenAI", url: "https://api.openai.com"),
    (name: "Ollama", url: "http://localhost:11434"),
  ]

  // MARK: - Ollama

  private var ollamaSettings: some View {
    Form {
      Section(String(localized: "settings.ollama.section.connection")) {
        LabeledContent(String(localized: "settings.ollama.base_url")) {
          TextField(
            String(localized: "settings.ollama.base_url.placeholder"),
            text: $ollamaURL
          )
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.leading)
          .frame(width: 240)
          .font(.callout)
          .autocorrectionDisabled()
        }

        LabeledContent(String(localized: "settings.ollama.status.label")) {
          HStack(spacing: 10) {
            if let result = ollamaTestResult {
              HStack(spacing: 5) {
                Circle()
                  .fill(result ? Color.green : Color.red)
                  .frame(width: 7, height: 7)
                Text(
                  result
                    ? String(localized: "settings.ollama.status.connected")
                    : String(localized: "settings.ollama.status.unreachable")
                )
                .font(.callout)
                .foregroundStyle(result ? .green : .red)
              }
              .accessibilityElement(children: .combine)
            }
            Button {
              isTestingOllama = true
              ollamaTestResult = nil
              state.ollamaBaseURL = ollamaURL
              state.contextTokenLimit = contextTokenLimit
              Task {
                await state.applySettings()
                ollamaTestResult = state.ollamaReachable
                isTestingOllama = false
                presentToast(
                  success: state.ollamaReachable,
                  message: state.ollamaReachable
                    ? String(localized: "settings.ollama.status.connected")
                    : String(localized: "settings.ollama.status.unreachable")
                )
              }
            } label: {
              HStack(spacing: 4) {
                if isTestingOllama {
                  ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
                }
                Text("settings.ollama.test_connection")
              }
            }
            .buttonStyle(.bordered)
            .disabled(isTestingOllama || ollamaURL.isEmpty)
          }
        }
      }

      Section(
        String(
          format: String(localized: "settings.ollama.installed_models"), state.ollamaModels.count)
      ) {
        if state.ollamaModels.isEmpty {
          if !state.ollamaReachable {
            Label(
              String(localized: "settings.ollama.start_hint"),
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            .font(.callout)
          } else {
            Label(String(localized: "settings.ollama.pull_hint"), systemImage: "tray")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
        } else {
          ForEach(state.ollamaModels) { model in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                  .font(.callout)
                  .fontWeight(.medium)
                if !model.sizeFormatted.isEmpty {
                  Text(model.sizeFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - MLX

  @State private var mlxLoadingId: String?

  private var mlxSettings: some View {
    Form {
      Section(String(localized: "settings.mlx.section.title")) {
        Text("settings.mlx.description")
          .font(.callout)
          .foregroundStyle(.secondary)
        if !mlxService.isAvailable {
          Label(
            String(localized: "settings.mlx.unavailable"), systemImage: "exclamationmark.triangle"
          )
          .font(.callout)
          .foregroundStyle(.orange)
        }
      }

      Section(String(localized: "settings.mlx.section.models")) {
        ForEach(MLXModelInfo.bundled) { model in
          mlxModelRow(model)
        }
      }

      if mlxService.loadedModelId != nil {
        Section {
          Button(String(localized: "settings.mlx.unload_button"), role: .destructive) {
            mlxService.unloadModel()
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func mlxModelRow(_ model: MLXModelInfo) -> some View {
    let downloadState = mlxService.downloadStates[model.repoId] ?? .notDownloaded
    let isLoaded = mlxService.loadedModelId == model.repoId
    let isThisLoading = mlxService.isLoading && mlxLoadingId == model.repoId

    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(model.name)
          .font(.callout)
          .fontWeight(.medium)
        Text(model.description)
          .font(.caption)
          .foregroundStyle(.secondary)
        if case .downloaded = downloadState,
          let size = mlxService.formattedDiskSize(for: model.repoId)
        {
          Text(size)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        if case .failed(let msg) = downloadState {
          Text(msg)
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(2)
        }
      }

      Spacer()

      mlxModelActions(
        model: model,
        downloadState: downloadState,
        isLoaded: isLoaded,
        isThisLoading: isThisLoading
      )
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func mlxModelActions(
    model: MLXModelInfo,
    downloadState: MLXDownloadState,
    isLoaded: Bool,
    isThisLoading: Bool
  ) -> some View {
    switch downloadState {
    case .notDownloaded:
      Button {
        mlxService.downloadModel(repoId: model.repoId)
      } label: {
        Label(String(localized: "settings.mlx.download_button"), systemImage: "arrow.down.circle")
          .font(.callout)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(!mlxService.isAvailable)

    case .downloading(let progress):
      HStack(spacing: 8) {
        VStack(alignment: .trailing, spacing: 2) {
          ProgressView(value: progress)
            .frame(width: 90)
          Text("\(Int(progress * 100))%")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        // These downloads run to tens of gigabytes; starting one by mistake used to
        // mean quitting the app to stop it.
        Button(role: .destructive) {
          mlxService.cancelDownload(repoId: model.repoId)
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(String(localized: "settings.mlx.cancel_help"))
        .accessibilityLabel(Text("settings.mlx.cancel_help"))
      }

    case .downloaded:
      HStack(spacing: 8) {
        if isThisLoading {
          HStack(spacing: 6) {
            ProgressView()
              .scaleEffect(0.7)
              .frame(width: 14, height: 14)
            Text(String(localized: "settings.mlx.loading"))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        } else if isLoaded {
          Label(String(localized: "settings.mlx.loaded"), systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        } else {
          Button(String(localized: "settings.mlx.load_button")) {
            mlxLoadingId = model.repoId
            state.selectedMLXModel = model
            Task {
              do {
                try await mlxService.loadModel(repoId: model.repoId)
              } catch {
                presentToast(success: false, message: error.localizedDescription)
              }
              mlxLoadingId = nil
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(mlxService.isLoading)
        }

        Button(role: .destructive) {
          mlxService.deleteModel(repoId: model.repoId)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .help(String(localized: "settings.mlx.delete_help"))
        .accessibilityLabel(Text("settings.mlx.delete_help"))
        .disabled(isThisLoading)
      }

    case .failed:
      Button {
        mlxService.downloadModel(repoId: model.repoId)
      } label: {
        Label(String(localized: "settings.mlx.retry_button"), systemImage: "arrow.clockwise")
          .font(.callout)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .tint(.orange)
      .disabled(!mlxService.isAvailable)
    }
  }

  // MARK: - Appearance

  @AppStorage("colorScheme") private var colorSchemeRaw: String = "system"

  private var appearanceSettings: some View {
    Form {
      Section(String(localized: "settings.appearance.section")) {
        Picker(String(localized: "settings.appearance.color_scheme"), selection: $colorSchemeRaw) {
          Text("settings.appearance.system").tag("system")
          Text("settings.appearance.light").tag("light")
          Text("settings.appearance.dark").tag("dark")
        }
        .pickerStyle(.radioGroup)
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Toast

  private func presentToast(success: Bool, message: String) {
    toastSuccess = success
    toastMessage = message
    showToast = true
    // Cancellable, so a second test result does not get hidden early by the first
    // one's timer.
    toastDismissTask?.cancel()
    toastDismissTask = Task {
      try? await Task.sleep(for: .milliseconds(2500))
      guard !Task.isCancelled else { return }
      showToast = false
    }
  }

  // MARK: - Apply

  private func apply() {
    state.ollamaBaseURL = ollamaURL
    state.systemPrompt = systemPrompt
    state.temperature = temperature
    state.contextTokenLimit = contextTokenLimit
    Task {
      await state.applySettings()
      // Applied unconditionally: skipping this when the field is empty made it
      // impossible to clear a configured gateway — the old URL stayed in defaults.
      await state.applyGatewaySettings(baseURL: gatewayURL, apiKey: gatewayAPIKey)
    }
  }
}
