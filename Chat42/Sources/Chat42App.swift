import SwiftUI

@main
struct Chat42App: App {
  @State private var appState = AppState()
  private let mlxService = MLXService.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(appState)
        .environment(mlxService)
        .frame(minWidth: 800, minHeight: 600)
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands {
      CommandGroup(after: .newItem) {
        Button(String(localized: "menu.new_chat")) {
          appState.newConversation()
        }
        .keyboardShortcut("n", modifiers: .command)
        Divider()
      }
      CommandMenu("Model") {
        ForEach(AIBackend.allCases, id: \.self) { backend in
          Button(backend.rawValue) {
            appState.activeBackend = backend
          }
          .tag(backend)
        }
        Divider()
        Button(String(localized: "menu.refresh_models")) {
          Task { await appState.refreshOllamaModels() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }
    }

    Settings {
      SettingsView()
        .environment(appState)
        .environment(mlxService)
    }
  }
}
