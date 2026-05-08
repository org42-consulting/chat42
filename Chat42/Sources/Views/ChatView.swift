import SwiftUI

struct ChatView: View {
  @Environment(AppState.self) private var state
  let conversation: Conversation
  @State private var inputText = ""
  @State private var scrollProxy: ScrollViewProxy?
  @State private var pendingAttachments: [AttachedFile] = []

  var visibleMessages: [Message] {
    conversation.messages.filter { $0.role != .system }
  }

  var body: some View {
    VStack(spacing: 0) {
      chatToolbar
      Divider()
      if visibleMessages.isEmpty {
        welcomeView
      } else {
        messageList
      }
      ChatInputView(inputText: $inputText, onSend: sendMessage, pendingAttachments: $pendingAttachments)
        .environment(state)
    }
    .onChange(of: conversation.id) {
      pendingAttachments = []
    }
  }

  // MARK: - Toolbar

  private var chatToolbar: some View {
    HStack(spacing: 12) {
      ModelSelectorView()
        .environment(state)
      Spacer()
      if state.isSending {
        HStack(spacing: 6) {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 14, height: 14)
          Text("chat.generating")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Button {
        clearConversation()
      } label: {
        Image(systemName: "trash")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help(String(localized: "chat.clear"))
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  // MARK: - Welcome

  private var welcomeView: some View {
    VStack(spacing: 24) {
      Spacer()
      VStack(spacing: 12) {
        Image("org42-logo-text")
          .resizable()
          .scaledToFit()
          .frame(width: 260)
        Text("sidebar.title")
          .font(.largeTitle)
          .fontWeight(.bold)
        Text("chat.welcome.subtitle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 8) {
        Text("chat.welcome.try_asking")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 32)

        ForEach(starterPromptKeys, id: \.self) { key in
          let localizedPrompt = String(localized: String.LocalizationValue(key))
          Button {
            inputText = localizedPrompt
          } label: {
            HStack {
              Text(localizedPrompt)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
              Spacer()
              Image(systemName: "arrow.up.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 32)
        }
      }
      .frame(maxWidth: 520)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private let starterPromptKeys = [
    "chat.starter.quantum",
    "chat.starter.python",
    "chat.starter.swift_concurrency",
    "chat.starter.swiftui",
  ]

  // MARK: - Message list

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 16) {
          ForEach(visibleMessages) { message in
            MessageBubbleView(message: message)
              .id(message.id)
              .transition(.opacity.combined(with: .move(edge: .bottom)))
          }
        }
        .padding(.vertical, 16)
        .animation(.easeOut(duration: 0.2), value: visibleMessages.count)
      }
      .scrollContentBackground(.hidden)
      .background(.clear)
      .onAppear { scrollProxy = proxy }
      .onChange(of: conversation.messages.count) { scrollToBottom() }
      .onChange(of: conversation.messages.last?.content) {
        if conversation.messages.last?.isStreaming == true { scrollToBottom() }
      }
    }
  }

  private func scrollToBottom() {
    guard let lastId = visibleMessages.last?.id else { return }
    withAnimation(.easeOut(duration: 0.2)) {
      scrollProxy?.scrollTo(lastId, anchor: .bottom)
    }
  }

  // MARK: - Actions

  private func sendMessage() {
    let text = inputText
    let attachments = pendingAttachments
    inputText = ""
    pendingAttachments = []
    Task { await state.sendMessage(text, attachments: attachments) }
  }

  private func clearConversation() {
    conversation.messages = conversation.messages.filter { $0.role == .system }
    state.persistConversations()
  }
}
