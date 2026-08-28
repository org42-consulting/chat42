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
        .task { await start() }
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands { commands }

    // Always reachable, without hunting for the window. Paired with the global
    // hotkey this is what makes the app answerable mid-task rather than somewhere
    // you go.
    MenuBarExtra("Chat42", systemImage: "bubble.left.and.bubble.right.fill") {
      QuickAskView()
        .environment(appState)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
        .environment(appState)
        .environment(mlxService)
    }
  }

  // MARK: - Launch

  @MainActor
  private func start() async {
    // Conversations are written on a coalescing timer; quitting has to flush
    // whatever is still pending or the last turn of a session is lost.
    appDelegate.flushBeforeTermination = { @MainActor in
      await appState.saveNow()
    }

    // Services menu: "Ask Chat42" on a selection in any app.
    appDelegate.serviceProvider.onText = { text in
      let conversation = appState.newConversation()
      appState.selectedConversationId = conversation.id
      appState.sendMessage(text)
    }

    HotKeyManager.shared.setHandler {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
    HotKeyManager.shared.register()

    // Reads the stored gateway key. After the window exists, so that a keychain
    // authorization prompt appears over a running app instead of blocking launch.
    await appState.loadGatewayCredentials()

    // Restores the model that was loaded when the app last quit, so the local
    // backend is usable without a trip through Settings first.
    await mlxService.autoLoadIfEnabled()
  }

  // MARK: - Menus

  @CommandsBuilder
  private var commands: some Commands {
    CommandGroup(after: .newItem) {
      Button(String(localized: "menu.new_chat")) {
        appState.newConversation()
      }
      .keyboardShortcut("n", modifiers: .command)

      // Start configured rather than retyping the same instructions.
      Menu(String(localized: "menu.new_from_preset")) {
        if appState.presets.isEmpty {
          Text("settings.presets.empty")
        } else {
          ForEach(appState.presets) { preset in
            Button(preset.displayName) {
              appState.newConversation(preset: preset)
            }
          }
        }
      }

      Button(String(localized: "chat.export.help")) {
        NotificationCenter.default.post(name: .chat42ExportRequested, object: nil)
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(appState.selectedConversation == nil)

      Divider()
    }

    CommandGroup(after: .textEditing) {
      Button(String(localized: "menu.find")) {
        appState.searchFocusRequest &+= 1
      }
      .keyboardShortcut("f", modifiers: .command)
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

    CommandMenu("menu.conversations") {
      Button(String(localized: "menu.next_conversation")) { cycleConversation(by: 1) }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
      Button(String(localized: "menu.previous_conversation")) { cycleConversation(by: -1) }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
      Divider()
      // ⌘1–9 jumps straight to a conversation, the way tabs work everywhere else.
      ForEach(1...9, id: \.self) { position in
        Button(String(format: String(localized: "menu.jump_to"), position)) {
          jumpToConversation(at: position - 1)
        }
        .keyboardShortcut(
          KeyEquivalent(Character("\(position)")), modifiers: .command)
      }
    }
  }

  @MainActor
  private func jumpToConversation(at index: Int) {
    let ordered = appState.conversationsByRecency
    guard index < ordered.count else { return }
    appState.selectedConversationId = ordered[index].id
  }

  @MainActor
  private func cycleConversation(by offset: Int) {
    let ordered = appState.conversationsByRecency
    guard !ordered.isEmpty else { return }
    guard let current = ordered.firstIndex(where: { $0.id == appState.selectedConversationId })
    else {
      appState.selectedConversationId = ordered.first?.id
      return
    }
    // Wraps, so repeated presses cycle rather than stalling at either end.
    let next = (current + offset + ordered.count) % ordered.count
    appState.selectedConversationId = ordered[next].id
  }
}

extension Notification.Name {
  /// Posted by the Export menu item. The save panel needs the conversation the
  /// chat view is showing, which the App scene has no direct handle on.
  static let chat42ExportRequested = Notification.Name("chat42.exportRequested")
}

/// Holds termination until the pending conversation write completes, and owns the
/// objects AppKit needs to outlive any particular view.
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor var flushBeforeTermination: (@MainActor () async -> Void)?
  let serviceProvider = ServiceProvider()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.servicesProvider = serviceProvider
    // Makes a newly added service appear without a logout; harmless afterwards.
    NSUpdateDynamicServices()
  }

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

  /// The menu bar item keeps the app useful with no windows open, so closing the
  /// last one should not quit.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}
