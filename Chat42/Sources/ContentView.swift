import AppKit
import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var state
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("colorScheme") private var colorSchemeRaw: String = "system"

  var preferredColorScheme: ColorScheme? {
    .chat42Override(colorSchemeRaw)
  }

  var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    } detail: {
      Group {
        if let conversation = state.selectedConversation {
          ChatView(conversation: conversation)
            .id(conversation.id)
        } else {
          noSelectionView
        }
      }
      .background(
        LinearGradient(
          colors: [
            colorScheme == .dark ? .black : .white,
            colorScheme == .dark
              ? Color(red: 0.363, green: 0.426, blue: 0.439)
              : Color(red: 0.725, green: 0.851, blue: 0.878),
          ],
          startPoint: .bottomLeading,
          endPoint: .topTrailing
        )
      )
    }
    .background(WindowConfigurator())
    .navigationSplitViewStyle(.balanced)
    .preferredColorScheme(preferredColorScheme)
    .task {
      await state.refreshOllamaModels()
      // Without this the Gateway backend shows "Offline" with an empty model list on
      // every launch until the user opens Settings or hits refresh by hand.
      if !state.gatewayBaseURL.isEmpty {
        await state.refreshGatewayModels()
      }
    }
    .alert(
      "alert.error.title",
      isPresented: Binding(
        get: { state.error != nil },
        set: { if !$0 { state.error = nil } }
      )
    ) {
      Button("alert.ok") { state.error = nil }
    } message: {
      Text(state.error ?? "")
    }
  }

  private var noSelectionView: some View {
    VStack(spacing: 16) {
      BrandLogoView()

      Text("chat.no_selection")
        .font(.callout)
        .foregroundStyle(.secondary)

      Button {
        state.newConversation()
      } label: {
        Text("chat.new")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut("n", modifiers: .command)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.clear)
  }
}

// MARK: - Appearance

extension ColorScheme {
  /// Maps the stored Appearance setting to an override, or nil to follow the system.
  ///
  /// Shared by every window the app owns rather than restated per view: the setting
  /// is app-wide, and a window that read it differently would sit in the wrong
  /// appearance beside the others.
  static func chat42Override(_ stored: String) -> ColorScheme? {
    switch stored {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
  }
}

// MARK: - Window configurator

private struct WindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      window.titlebarAppearsTransparent = true
      window.styleMask.insert(.fullSizeContentView)
      window.backgroundColor = .clear
    }
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
