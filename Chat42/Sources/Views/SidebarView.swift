import SwiftUI

struct SidebarView: View {
  @Environment(AppState.self) private var state
  @State private var showSettings = false
  @State private var searchText = ""
  @State private var renamingId: UUID?
  @State private var renameText = ""

  var filteredConversations: [Conversation] {
    guard !searchText.isEmpty else { return state.conversations }
    return state.conversations.filter {
      $0.displayTitle.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      sidebarHeader
      HStack {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.footnote)
        TextField(String(localized: "sidebar.search.placeholder"), text: $searchText)
          .textFieldStyle(.plain)
          .font(.callout)
        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color.sidebarSearch)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal, 12)
      .padding(.bottom, 8)

      Divider().opacity(0.3)

      if state.conversations.isEmpty {
        emptySidebar
      } else {
        conversationList
      }

      Divider().opacity(0.3)
      sidebarFooter
    }
    .background(Color.sidebarBackground)
    .sheet(isPresented: $showSettings) {
      SettingsView()
        .environment(state)
        .environment(MLXService.shared)
    }
  }

  // MARK: - Header

  private var sidebarHeader: some View {
    HStack {
      HStack(spacing: 6) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .foregroundStyle(Color.accentColor)
          .font(.title3)
        Text("sidebar.title")
          .font(.headline)
          .fontWeight(.semibold)
      }
      Spacer()
      Button {
        state.newConversation()
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.title3)
          .foregroundStyle(.primary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(String(localized: "sidebar.new_chat.help"))
      .keyboardShortcut("n", modifiers: .command)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  // MARK: - Conversation list

  private var conversationList: some View {
    List(
      selection: Binding(
        get: { state.selectedConversationId },
        set: { state.selectedConversationId = $0 }
      )
    ) {
      ForEach(filteredConversations) { conv in
        conversationRow(conv)
          .tag(conv.id)
          .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
              .fill(
                state.selectedConversationId == conv.id
                  ? Color.accentColor.opacity(0.2)
                  : Color.clear
              )
              .padding(.horizontal, 4)
          )
          .listRowSeparator(.hidden)
      }
      .onDelete { state.deleteConversations(at: $0) }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }

  @ViewBuilder
  private func conversationRow(_ conv: Conversation) -> some View {
    if renamingId == conv.id {
      TextField(String(localized: "sidebar.rename.placeholder"), text: $renameText)
        .textFieldStyle(.plain)
        .font(.callout)
        .onSubmit {
          state.renameConversation(conv, title: renameText)
          renamingId = nil
        }
        .onExitCommand { renamingId = nil }
    } else {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(conv.displayTitle)
            .font(.callout)
            .fontWeight(.medium)
            .lineLimit(1)
          HStack(spacing: 4) {
            Image(systemName: conv.backend == .ollama ? "server.rack" : "apple.terminal")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Text(conv.modelName.isEmpty ? "—" : conv.modelName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
      }
      .padding(.vertical, 2)
      .contextMenu {
        Button(String(localized: "sidebar.context.rename")) {
          renameText = conv.displayTitle
          renamingId = conv.id
        }
        Divider()
        Button(String(localized: "sidebar.context.delete"), role: .destructive) {
          state.deleteConversation(conv)
        }
      }
    }
  }

  // MARK: - Empty state

  private var emptySidebar: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 36))
        .foregroundStyle(.tertiary)
      Text("sidebar.empty.title")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button {
        state.newConversation()
      } label: {
        Text("sidebar.empty.button")
      }
      .buttonStyle(.bordered)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Footer

  private var sidebarFooter: some View {
    HStack {
      Button {
        showSettings = true
      } label: {
        Label(String(localized: "sidebar.settings"), systemImage: "gear")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      Spacer()
      HStack(spacing: 8) {
        statusDot(
          reachable: state.ollamaReachable,
          onLabel: String(localized: "sidebar.ollama.online"),
          offLabel: String(localized: "sidebar.ollama.offline"))

        if state.activeBackend == .gateway || state.gatewayReachable {
          statusDot(
            reachable: state.gatewayReachable,
            onLabel: String(localized: "sidebar.gateway.online"),
            offLabel: String(localized: "sidebar.gateway.offline"))
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

private func statusDot(reachable: Bool, onLabel: String, offLabel: String) -> some View {
  HStack(spacing: 4) {
    Circle()
      .fill(reachable ? Color.green : Color.red)
      .frame(width: 6, height: 6)
    Text(reachable ? onLabel : offLabel)
      .font(.caption2)
      .foregroundStyle(.secondary)
  }
}

extension Color {
  static let sidebarBackground = Color(NSColor.controlBackgroundColor).opacity(0.6)
  static let sidebarSearch = Color.primary.opacity(0.06)
}
