import AppKit
import SwiftUI

@main
struct Chat42App: App {
  @State private var appState = AppState()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let mlxService = MLXService.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(appState)
        .environment(mlxService)
        .frame(minWidth: 800, minHeight: 600)
        .task {
          // Conversations are written on a coalescing timer; quitting has to flush
          // whatever is still pending or the last turn of a session is lost.
          appDelegate.flushBeforeTermination = { @MainActor in
            await appState.saveNow()
          }
        }
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
      CommandMenu("menu.model") {
        ForEach(AIBackend.allCases, id: \.self) { backend in
          Button(backend.rawValue) {
            appState.activeBackend = backend
          }
          .tag(backend)
        }
        Divider()
        Button(String(localized: "menu.refresh_models")) {
          Task {
            await appState.refreshOllamaModels()
            if !appState.gatewayBaseURL.isEmpty {
              await appState.refreshGatewayModels()
            }
          }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        Divider()
        Button(String(localized: "message.regenerate")) {
          if let conversation = appState.selectedConversation {
            appState.regenerate(in: conversation)
          }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(appState.selectedConversation?.isSending ?? true)
      }
    }

    Settings {
      SettingsView()
        .environment(appState)
        .environment(mlxService)
    }
  }
}

/// Holds termination until the pending conversation write completes.
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor var flushBeforeTermination: (@MainActor () async -> Void)?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      guard let flush = flushBeforeTermination else { return .terminateNow }
      Task { @MainActor in
        await flush()
        NSApp.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
