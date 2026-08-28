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
  @State private var showPinnedDocuments = false

  var visibleMessages: [Message] {
    conversation.messages.filter { $0.role != .system }
  }

  /// One entry per rendered row. Replies that answered the same question on
  /// different models are collapsed into a single `.comparison` row so they can be
  /// drawn as columns rather than stacked.
  private enum TranscriptRow: Identifiable {
    case single(Message)
    case comparison(groupId: UUID, messages: [Message])

    var id: UUID {
      switch self {
      case .single(let message): return message.id
      case .comparison(let groupId, _): return groupId
      }
    }
  }

  private var transcriptRows: [TranscriptRow] {
    var rows: [TranscriptRow] = []
    let messages = visibleMessages
    var index = 0
    while index < messages.count {
      let message = messages[index]
      guard let groupId = message.comparisonGroupId else {
        rows.append(.single(message))
        index += 1
        continue
      }
      var group: [Message] = []
      while index < messages.count, messages[index].comparisonGroupId == groupId {
        group.append(messages[index])
        index += 1
      }
      rows.append(.comparison(groupId: groupId, messages: group))
    }
    return rows
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
    // ⌘E lives in the App scene, which has no handle on the conversation being
    // shown; the chat view answers for whichever one is on screen.
    .onReceive(NotificationCenter.default.publisher(for: .chat42ExportRequested)) { _ in
      export()
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
      pinnedDocumentsButton
      comparisonMenu

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

  private var pinnedDocumentsButton: some View {
    Button {
      showPinnedDocuments = true
    } label: {
      Image(systemName: conversation.pinnedDocuments.isEmpty ? "pin" : "pin.fill")
        .font(.callout)
        .foregroundStyle(conversation.pinnedDocuments.isEmpty ? .secondary : Color.accentColor)
    }
    .buttonStyle(.plain)
    .help(String(localized: "chat.pinned.help"))
    .accessibilityLabel(Text("chat.pinned.help"))
    .popover(isPresented: $showPinnedDocuments, arrowEdge: .bottom) {
      PinnedDocumentsView(conversation: conversation)
        .environment(state)
    }
  }

  /// Picks a second model to answer every turn alongside the first.
  private var comparisonMenu: some View {
    Menu {
      Button(String(localized: "chat.compare.off")) {
        state.setComparison(nil, in: conversation)
      }
      Divider()
      ForEach(state.availableModels) { ref in
        Button {
          state.setComparison(ref, in: conversation)
        } label: {
          HStack {
            Text(ref.fullLabel)
            if conversation.compareWith == ref {
              Spacer()
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      Image(
        systemName: conversation.compareWith == nil
          ? "rectangle.split.2x1" : "rectangle.split.2x1.fill"
      )
      .font(.callout)
      .foregroundStyle(conversation.compareWith == nil ? .secondary : Color.accentColor)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(String(localized: "chat.compare.help"))
    .accessibilityLabel(Text("chat.compare.help"))
  }

  // MARK: - Welcome

  private var welcomeView: some View {
    VStack(spacing: 24) {
      Spacer()
      VStack(spacing: 12) {
        BrandLogoView()
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
          ForEach(transcriptRows) { row in
            switch row {
            case .single(let message):
              MessageBubbleView(
                message: message,
                conversation: conversation,
                canRegenerate: message.id == lastAssistantMessageId
              )
              .environment(state)
              .id(message.id)
              .transition(.opacity.combined(with: .move(edge: .bottom)))

            case .comparison(let groupId, let messages):
              comparisonRow(messages)
                .id(groupId)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
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

  /// Two replies to the same question, side by side, each captioned with its model.
  private func comparisonRow(_ messages: [Message]) -> some View {
    HStack(alignment: .top, spacing: 12) {
      ForEach(messages) { message in
        VStack(alignment: .leading, spacing: 4) {
          Text(message.modelRef?.fullLabel ?? "")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          MessageBubbleView(
            message: message,
            conversation: conversation,
            canRegenerate: false,
            isComparisonColumn: true
          )
          .environment(state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
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
