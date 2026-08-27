import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
  @Environment(AppState.self) private var state
  let conversation: Conversation
  @State private var inputText = ""
  @State private var scrollProxy: ScrollViewProxy?
  @State private var pendingAttachments: [AttachedFile] = []
  @State private var showClearConfirmation = false

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
      ChatInputView(
        conversation: conversation,
        inputText: $inputText,
        onSend: sendMessage,
        pendingAttachments: $pendingAttachments
      )
      .environment(state)
    }
    .onChange(of: conversation.id) {
      pendingAttachments = []
    }
    .confirmationDialog(
      String(localized: "chat.clear.confirm.title"),
      isPresented: $showClearConfirmation
    ) {
      Button(String(localized: "chat.clear.confirm.action"), role: .destructive) {
        state.clearConversation(conversation)
      }
      Button(String(localized: "alert.cancel"), role: .cancel) {}
    } message: {
      Text("chat.clear.confirm.message")
    }
  }

  // MARK: - Toolbar

  private var chatToolbar: some View {
    HStack(spacing: 12) {
      ModelSelectorView()
        .environment(state)
      Spacer()
      if conversation.isSending {
        HStack(spacing: 6) {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 14, height: 14)
          Text(conversation.isGeneratingImage ? "chat.generating_image" : "chat.generating")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Button {
        export()
      } label: {
        Image(systemName: "square.and.arrow.up")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help(String(localized: "chat.export.help"))
      .accessibilityLabel(Text("chat.export.help"))
      .disabled(visibleMessages.isEmpty)

      Button {
        showClearConfirmation = true
      } label: {
        Image(systemName: "trash")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help(String(localized: "chat.clear"))
      .accessibilityLabel(Text("chat.clear"))
      .disabled(visibleMessages.isEmpty)
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
          .accessibilityHidden(true)
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
            MessageBubbleView(
              message: message,
              conversation: conversation,
              canRegenerate: message.id == lastAssistantMessageId
            )
            .environment(state)
            .id(message.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
          }
        }
        .padding(.vertical, 16)
        .animation(.easeOut(duration: 0.2), value: visibleMessages.count)
      }
      .scrollContentBackground(.hidden)
      .background(.clear)
      .onAppear {
        scrollProxy = proxy
        scrollToBottom(animated: false)
      }
      .onChange(of: conversation.messages.count) { scrollToBottom(animated: true) }
      .onChange(of: conversation.messages.last?.content) {
        // Unanimated during streaming: the content updates ~20 times a second, and
        // starting an animation per update stacks them into a visible stutter.
        if conversation.messages.last?.isStreaming == true { scrollToBottom(animated: false) }
      }
    }
  }

  private var lastAssistantMessageId: UUID? {
    conversation.messages.last(where: { $0.role == .assistant })?.id
  }

  private func scrollToBottom(animated: Bool) {
    guard let lastId = visibleMessages.last?.id else { return }
    if animated {
      withAnimation(.easeOut(duration: 0.2)) {
        scrollProxy?.scrollTo(lastId, anchor: .bottom)
      }
    } else {
      scrollProxy?.scrollTo(lastId, anchor: .bottom)
    }
  }

  // MARK: - Actions

  private func sendMessage() {
    let text = inputText
    let attachments = pendingAttachments
    inputText = ""
    pendingAttachments = []
    state.sendMessage(text, attachments: attachments)
  }

  private func export() {
    let markdown = state.exportMarkdown(conversation)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = "\(sanitizedFilename(conversation.displayTitle)).md"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      DispatchQueue.main.async {
        do {
          try Data(markdown.utf8).write(to: url)
        } catch {
          state.error = error.localizedDescription
        }
      }
    }
  }

  private func sanitizedFilename(_ title: String) -> String {
    let cleaned = title.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
      .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "conversation" : String(cleaned.prefix(60))
  }
}
