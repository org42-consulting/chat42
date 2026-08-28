import SwiftUI

struct SidebarView: View {
  @Environment(AppState.self) private var state
  @State private var searchText = ""
  @State private var renamingId: UUID?
  @State private var renameText = ""
  @FocusState private var isSearchFocused: Bool

  /// Most recently active first, filtered by a search that reads the whole
  /// transcript — not just the title, which was the only thing it used to match.
  var filteredConversations: [Conversation] {
    let ordered = state.conversationsByRecency
    guard !searchText.isEmpty else { return ordered }
    return ordered.filter { $0.matches(searchText) }
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
          .focused($isSearchFocused)
          .accessibilityLabel(Text("sidebar.search.placeholder"))
        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help(String(localized: "sidebar.search.clear"))
          .accessibilityLabel(Text("sidebar.search.clear"))
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
    .onChange(of: state.searchFocusRequest) { isSearchFocused = true }
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
      .accessibilityLabel(Text("sidebar.new_chat.help"))
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
      .onDelete { state.deleteConversations(at: $0, in: filteredConversations) }
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
            Image(systemName: conv.backend.systemImage)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
            Text(conv.modelName.isEmpty ? "—" : conv.modelName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            if let preset = state.preset(id: conv.presetId) {
              Text(preset.displayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .lineLimit(1)
            }
            if !conv.pinnedDocuments.isEmpty {
              Label("\(conv.pinnedDocuments.count)", systemImage: "paperclip")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }
          }
          // When the hit was in the body rather than the title, show where.
          if !searchText.isEmpty,
            !conv.displayTitle.localizedCaseInsensitiveContains(searchText),
            let snippet = conv.snippet(matching: searchText)
          {
            Text(snippet)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(2)
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
      // Opens the app's one Settings scene. Presenting a second copy as a sheet
      // meant two independent instances with different window chrome, and edits in
      // one were invisible to the other.
      SettingsLink {
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
      .accessibilityHidden(true)
    Text(reachable ? onLabel : offLabel)
      .font(.caption2)
      .foregroundStyle(.secondary)
  }
  // Colour alone must not be the only channel: the label already carries the state
  // in words, so the combined element reads correctly.
  .accessibilityElement(children: .combine)
}

extension Color {
  static let sidebarBackground = Color(NSColor.controlBackgroundColor).opacity(0.6)
  static let sidebarSearch = Color.primary.opacity(0.06)
}
