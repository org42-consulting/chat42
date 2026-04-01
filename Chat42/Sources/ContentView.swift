import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("colorScheme") private var colorSchemeRaw: String = "system"

    var preferredColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            Group {
                if let conversation = state.selectedConversation {
                    ChatView(conversation: conversation).id(conversation.id) // re-creates view when switching conversations
                } else {
                    noSelectionView
                }
            }
            .background(
                LinearGradient(
                    colors: [colorScheme == .dark ? .black : .white, Color(red: 0.725, green: 0.851, blue: 0.878)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
        }
        .background(WindowConfigurator())
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(preferredColorScheme)
        .task {
            // Auto-connect to Ollama on launch
            await state.refreshOllamaModels()
        }
        .alert("Error", isPresented: Binding(
            get: { state.error != nil },
            set: { if !$0 { state.error = nil } }
        )) {
            Button("OK") { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
    }

    private var noSelectionView: some View {
        VStack(spacing: 16) {
            Image("org42-logo-text")
                .resizable()
                .scaledToFit()
                .frame(width: 260)

            Text("sidebar.title")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("chat.no_selection")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button { state.newConversation() } label: {
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
