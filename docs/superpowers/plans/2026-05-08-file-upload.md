# File Upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to attach text files, images, and PDFs to outgoing chat messages, with content injected into the API payload at send-time and lightweight metadata shown in the message bubble.

**Architecture:** Attachments are staged transiently in `ChatView` state as `[AttachedFile]`. On send, `AttachmentProcessor` extracts text/PDF content (prepended to the API payload) and base64-encodes images (passed via `ChatMessage.images`). `Message.content` stores only the user's typed text; `Message.attachments` stores display metadata. Raw bytes are never persisted.

**Tech Stack:** SwiftUI, AppKit (NSOpenPanel), PDFKit, UniformTypeIdentifiers, `@Observable`, existing Ollama/Gateway/MLX services.

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Create | `Sources/Models/AttachedFile.swift` | `AttachmentType`, `AttachedFile`, `MessageAttachment` |
| Modify | `Sources/Models/Message.swift` | Add `attachments` to `Message`, `MessageDTO`, `ChatMessage` |
| Create | `Sources/Services/AttachmentProcessor.swift` | Classify files, extract text/PDF, base64-encode images |
| Modify | `Sources/Services/GatewayService.swift` | `ContentPayload` enum, multimodal `GatewayChatMessage` |
| Modify | `Sources/Services/OllamaService.swift` | `images: [String]?` on `OllamaChatMessage` |
| Modify | `Sources/AppState.swift` | Accept `[AttachedFile]` in `sendMessage`, inject context |
| Create | `Sources/Views/AttachmentChipView.swift` | Single chip (staged + read-only variants) |
| Create | `Sources/Views/AttachmentRowView.swift` | Horizontal scrolling row of chips |
| Modify | `Sources/Views/ChatInputView.swift` | Paperclip button, drop target, `pendingAttachments` binding |
| Modify | `Sources/Views/ChatView.swift` | `pendingAttachments` state, updated send call |
| Modify | `Sources/Views/MessageBubbleView.swift` | Read-only chip row above bubble text |
| Modify | `Resources/en.lproj/Localizable.strings` | New error + UI strings |
| Modify | `Resources/nl.lproj/Localizable.strings` | Dutch translations |

---

## Task 1: Attachment data types

**Files:**
- Create: `Chat42/Sources/Models/AttachedFile.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation
import UniformTypeIdentifiers

enum AttachmentType: String, Codable, Hashable {
  case text, image, pdf

  var systemImage: String {
    switch self {
    case .text: return "doc.text"
    case .image: return "photo"
    case .pdf: return "doc.richtext"
    }
  }
}

struct AttachedFile: Identifiable {
  let id: UUID
  let url: URL
  let name: String
  let type: AttachmentType
  let data: Data
  let mimeType: String  // e.g. "image/jpeg"
}

struct MessageAttachment: Codable, Identifiable, Hashable {
  let id: UUID
  let name: String
  let type: AttachmentType
}
```

- [ ] **Step 2: Build in Xcode (⌘B) — expect success**

- [ ] **Step 3: Commit**

```bash
git add Chat42/Sources/Models/AttachedFile.swift
git commit -m "feat: add AttachmentType, AttachedFile, MessageAttachment types"
```

---

## Task 2: Update Message model

**Files:**
- Modify: `Chat42/Sources/Models/Message.swift`

- [ ] **Step 1: Add `attachments` to `Message` and its initializer**

Replace the `Message` class:

```swift
@Observable
final class Message: Identifiable, Hashable {
  let id: UUID
  var role: MessageRole
  var content: String
  var isStreaming: Bool
  let timestamp: Date
  var attachments: [MessageAttachment]

  init(
    id: UUID = UUID(), role: MessageRole, content: String, isStreaming: Bool = false,
    timestamp: Date = .now, attachments: [MessageAttachment] = []
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.isStreaming = isStreaming
    self.timestamp = timestamp
    self.attachments = attachments
  }

  static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
```

- [ ] **Step 2: Add `images` to `ChatMessage`**

Replace the `ChatMessage` struct:

```swift
struct ChatMessage: Sendable {
  let role: MessageRole
  let content: String
  var images: [String]? = nil  // data URI strings, e.g. "data:image/jpeg;base64,..."
}
```

- [ ] **Step 3: Update `MessageDTO` to include attachments**

Replace `MessageDTO`:

```swift
struct MessageDTO: Codable {
  let id: UUID
  let role: MessageRole
  let content: String
  let timestamp: Date
  let attachments: [MessageAttachment]

  init(from message: Message) {
    id = message.id
    role = message.role
    content = message.content
    timestamp = message.timestamp
    attachments = message.attachments
  }

  func toMessage() -> Message {
    Message(id: id, role: role, content: content, timestamp: timestamp, attachments: attachments)
  }
}
```

- [ ] **Step 4: Build (⌘B) — expect success**

- [ ] **Step 5: Commit**

```bash
git add Chat42/Sources/Models/Message.swift
git commit -m "feat: add attachments to Message and images to ChatMessage"
```

---

## Task 3: AttachmentProcessor

**Files:**
- Create: `Chat42/Sources/Services/AttachmentProcessor.swift`

- [ ] **Step 1: Create the processor**

```swift
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AttachmentProcessingError: LocalizedError {
  case pdfExtractionFailed(String)
  case unreadable(String)
  case unsupportedType(String)

  var errorDescription: String? {
    switch self {
    case .pdfExtractionFailed(let name): return "Could not extract text from \(name)"
    case .unreadable(let name): return "Could not read \(name)"
    case .unsupportedType(let name): return "Unsupported file type: \(name)"
    }
  }
}

struct AttachmentProcessor {

  static func attachmentType(for url: URL) -> AttachmentType? {
    guard let uttype = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    else { return nil }
    if uttype.conforms(to: .image) { return .image }
    if uttype.conforms(to: .pdf) { return .pdf }
    if uttype.conforms(to: .text) { return .text }
    return nil
  }

  static func makeAttachedFile(url: URL) throws -> AttachedFile {
    guard let type = attachmentType(for: url) else {
      throw AttachmentProcessingError.unsupportedType(url.lastPathComponent)
    }
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
      throw AttachmentProcessingError.unreadable(url.lastPathComponent)
    }
    let uttype = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    let mimeType = uttype?.preferredMIMEType ?? "application/octet-stream"
    return AttachedFile(
      id: UUID(), url: url, name: url.lastPathComponent,
      type: type, data: data, mimeType: mimeType
    )
  }

  // Returns contextText (for text/PDF files) and imageDataURIs (for images).
  // contextText is prepended to the user message in the API payload only — not stored in Message.content.
  // imageDataURIs are "data:<mimeType>;base64,<encoded>" strings.
  static func process(_ attachments: [AttachedFile]) throws -> (contextText: String, imageDataURIs: [String]) {
    var blocks: [String] = []
    var imageDataURIs: [String] = []

    for file in attachments {
      switch file.type {
      case .text:
        let text = String(data: file.data, encoding: .utf8) ?? "<binary content>"
        blocks.append("[File: \(file.name)]\n\(text)\n---")

      case .pdf:
        guard let doc = PDFDocument(data: file.data) else {
          throw AttachmentProcessingError.pdfExtractionFailed(file.name)
        }
        let text = (0..<doc.pageCount)
          .compactMap { doc.page(at: $0)?.string }
          .joined(separator: "\n")
        blocks.append("[File: \(file.name)]\n\(text)\n---")

      case .image:
        imageDataURIs.append("data:\(file.mimeType);base64,\(file.data.base64EncodedString())")
      }
    }

    return (blocks.joined(separator: "\n\n"), imageDataURIs)
  }
}
```

- [ ] **Step 2: Build (⌘B) — expect success**

- [ ] **Step 3: Commit**

```bash
git add Chat42/Sources/Services/AttachmentProcessor.swift
git commit -m "feat: add AttachmentProcessor for text extraction, PDF, and image encoding"
```

---

## Task 4: Update GatewayService for multimodal

**Files:**
- Modify: `Chat42/Sources/Services/GatewayService.swift`

- [ ] **Step 1: Add multimodal content types after the existing `GatewayChatMessage` struct**

Replace `GatewayChatMessage` and add supporting types:

```swift
// Supports both plain-text and multimodal (image) content.
enum ContentPayload: Encodable {
  case text(String)
  case parts([ContentPart])

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .text(let string): try container.encode(string)
    case .parts(let parts): try container.encode(parts)
    }
  }
}

struct ContentPart: Encodable {
  let type: String
  let text: String?
  let imageURL: ImageURLPayload?

  enum CodingKeys: String, CodingKey {
    case type, text
    case imageURL = "image_url"
  }

  static func textPart(_ string: String) -> ContentPart {
    ContentPart(type: "text", text: string, imageURL: nil)
  }

  static func imagePart(dataURI: String) -> ContentPart {
    ContentPart(type: "image_url", text: nil, imageURL: ImageURLPayload(url: dataURI))
  }
}

struct ImageURLPayload: Encodable {
  let url: String
}

struct GatewayChatMessage: Encodable {
  let role: String
  let content: ContentPayload
}
```

- [ ] **Step 2: Update `chat()` to build multimodal messages from `ChatMessage.images`**

In the `chat()` method, replace the `chatMessages` mapping:

```swift
let chatMessages = messages.map { msg -> GatewayChatMessage in
  if let images = msg.images, !images.isEmpty {
    var parts: [ContentPart] = []
    if !msg.content.isEmpty { parts.append(.textPart(msg.content)) }
    parts += images.map { ContentPart.imagePart(dataURI: $0) }
    return GatewayChatMessage(role: msg.role.rawValue, content: .parts(parts))
  }
  return GatewayChatMessage(role: msg.role.rawValue, content: .text(msg.content))
}
```

- [ ] **Step 3: Build (⌘B) — expect success**

- [ ] **Step 4: Commit**

```bash
git add Chat42/Sources/Services/GatewayService.swift
git commit -m "feat: add multimodal ContentPayload to GatewayService"
```

---

## Task 5: Update OllamaService for images

**Files:**
- Modify: `Chat42/Sources/Services/OllamaService.swift`

- [ ] **Step 1: Add `images` field to `OllamaChatMessage`**

Replace `OllamaChatMessage`:

```swift
struct OllamaChatMessage: Codable {
  let role: String
  let content: String
  let images: [String]?  // raw base64 strings (no data URI prefix)
}
```

With `images: [String]?`, Swift's Codable auto-synthesis uses `encodeIfPresent`, so nil is omitted from the JSON output (Ollama ignores missing fields).

- [ ] **Step 2: Update `chat()` to pass images from `ChatMessage.images`**

In `OllamaService.chat()`, replace the `chatMessages` mapping:

```swift
let chatMessages = messages.map { msg -> OllamaChatMessage in
  // Strip the "data:<mime>;base64," prefix — Ollama expects raw base64.
  let base64Images = msg.images?.compactMap {
    $0.components(separatedBy: ",").last
  }
  return OllamaChatMessage(
    role: msg.role.rawValue,
    content: msg.content,
    images: base64Images?.isEmpty == false ? base64Images : nil
  )
}
```

- [ ] **Step 3: Build (⌘B) — expect success**

- [ ] **Step 4: Commit**

```bash
git add Chat42/Sources/Services/OllamaService.swift
git commit -m "feat: add image support to OllamaService"
```

---

## Task 6: Update AppState to accept and process attachments

**Files:**
- Modify: `Chat42/Sources/AppState.swift`

- [ ] **Step 1: Update `sendMessage` public signature**

Replace the `sendMessage` method:

```swift
func sendMessage(_ text: String, attachments: [AttachedFile] = []) async {
  activeSendTask?.cancel()
  activeSendTask = Task { [weak self] in
    await self?.performSendMessage(text, attachments: attachments)
  }
}
```

- [ ] **Step 2: Replace `performSendMessage` with the attachment-aware version**

Replace `private func performSendMessage(_ text: String) async` with:

```swift
private func performSendMessage(_ text: String, attachments: [AttachedFile] = []) async {
  let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedText.isEmpty || !attachments.isEmpty else { return }

  if selectedConversation == nil { newConversation() }
  guard let conversation = selectedConversation else { return }

  // Process attachments: extract text/PDF context and base64-encode images.
  let contextText: String
  let imageDataURIs: [String]
  do {
    (contextText, imageDataURIs) = try AttachmentProcessor.process(attachments)
  } catch {
    let errMsg = Message(
      role: .assistant,
      content: String(format: String(localized: "error.generic"), error.localizedDescription)
    )
    conversation.messages.append(errMsg)
    persistConversations()
    return
  }

  // MLX does not support image attachments.
  if activeBackend == .mlx && !imageDataURIs.isEmpty {
    let errMsg = Message(role: .assistant, content: String(localized: "error.mlx_no_images"))
    conversation.messages.append(errMsg)
    persistConversations()
    return
  }

  // Auto-title from first user message.
  if conversation.messages.filter({ $0.role == .user }).isEmpty {
    let titleSource = trimmedText.isEmpty ? (attachments.first?.name ?? "") : trimmedText
    let words = titleSource.split(separator: " ").prefix(6).joined(separator: " ")
    conversation.title = words.isEmpty ? "New Chat" : String(words)
  }

  // Append user message — content stores only the typed text for display.
  let messageAttachments = attachments.map {
    MessageAttachment(id: $0.id, name: $0.name, type: $0.type)
  }
  let userMessage = Message(role: .user, content: trimmedText, attachments: messageAttachments)
  conversation.messages.append(userMessage)
  conversation.updatedAt = .now

  let assistantMessage = Message(role: .assistant, content: "", isStreaming: true)
  conversation.messages.append(assistantMessage)

  isSending = true
  defer {
    isSending = false
    assistantMessage.isStreaming = false
    persistConversations()
  }

  do {
    // Build context messages from conversation history.
    var contextMessages = conversation.messages
      .filter { $0.role != .assistant || $0 !== assistantMessage }
      .map { ChatMessage(role: $0.role, content: $0.content) }

    // Inject file context and images into the current (last) user message only.
    if let lastIndex = contextMessages.indices.last {
      let base = contextMessages[lastIndex]
      let fullContent = contextText.isEmpty ? base.content : "\(contextText)\n\n\(base.content)"
      contextMessages[lastIndex] = ChatMessage(
        role: base.role,
        content: fullContent,
        images: imageDataURIs.isEmpty ? nil : imageDataURIs
      )
    }

    switch activeBackend {
    case .ollama:
      guard let model = selectedOllamaModel else {
        assistantMessage.content = String(localized: "error.no_ollama_model")
        return
      }
      let stream = await ollamaService.chat(model: model.name, messages: contextMessages, temperature: temperature)
      for try await token in stream {
        try Task.checkCancellation()
        assistantMessage.content += token
      }

    case .mlx:
      let mlx = MLXService.shared
      guard mlx.loadedModelId != nil else {
        assistantMessage.content = String(localized: "error.no_mlx_model")
        return
      }
      let stream = mlx.chat(messages: contextMessages, temperature: Float(temperature))
      for try await token in stream {
        try Task.checkCancellation()
        assistantMessage.content += token
      }

    case .gateway:
      guard let model = selectedGatewayModel else {
        assistantMessage.content = String(localized: "error.no_gateway_model")
        return
      }
      let stream = await gatewayService.chat(model: model.id, messages: contextMessages, temperature: temperature)
      for try await token in stream {
        try Task.checkCancellation()
        assistantMessage.content += token
      }
    }
  } catch is CancellationError {
    // Cancelled by user — keep partial response.
  } catch {
    assistantMessage.content = String(
      format: String(localized: "error.generic"), error.localizedDescription)
  }
}
```

- [ ] **Step 3: Build (⌘B) — expect success**

- [ ] **Step 4: Commit**

```bash
git add Chat42/Sources/AppState.swift
git commit -m "feat: sendMessage accepts attachments, injects context into API payload"
```

---

## Task 7: AttachmentChipView

**Files:**
- Create: `Chat42/Sources/Views/AttachmentChipView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

struct AttachmentChipView: View {
  let name: String
  let type: AttachmentType
  var onRemove: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: type.systemImage)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(name)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 120)
      if let onRemove {
        Button(action: onRemove) {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(0.08), in: Capsule())
  }
}
```

- [ ] **Step 2: Build (⌘B) — expect success**

- [ ] **Step 3: Commit**

```bash
git add Chat42/Sources/Views/AttachmentChipView.swift
git commit -m "feat: add AttachmentChipView (staged and read-only variants)"
```

---

## Task 8: AttachmentRowView

**Files:**
- Create: `Chat42/Sources/Views/AttachmentRowView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

struct AttachmentRowView: View {
  @Binding var attachments: [AttachedFile]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(attachments) { file in
          AttachmentChipView(name: file.name, type: file.type) {
            attachments.removeAll { $0.id == file.id }
          }
        }
      }
      .padding(.vertical, 2)
    }
  }
}
```

- [ ] **Step 2: Build (⌘B) — expect success**

- [ ] **Step 3: Commit**

```bash
git add Chat42/Sources/Views/AttachmentRowView.swift
git commit -m "feat: add AttachmentRowView (horizontal scrolling chip row)"
```

---

## Task 9: Update ChatInputView

**Files:**
- Modify: `Chat42/Sources/Views/ChatInputView.swift`

- [ ] **Step 1: Add imports and new properties at the top of `ChatInputView`**

Add `import UniformTypeIdentifiers` at the top of the file.

Add these properties to `ChatInputView`:

```swift
@Binding var pendingAttachments: [AttachedFile]
@State private var isDragOver: Bool = false
```

- [ ] **Step 2: Update `canSend` to allow sending with only attachments**

Replace `canSend`:

```swift
var canSend: Bool {
  (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    || !pendingAttachments.isEmpty)
    && !state.isSending
}
```

- [ ] **Step 3: Update `body` to show the attachment row and drop target**

Replace `body`:

```swift
var body: some View {
  VStack(spacing: 0) {
    Divider()

    if !pendingAttachments.isEmpty {
      AttachmentRowView(attachments: $pendingAttachments)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    HStack(alignment: .bottom, spacing: 10) {
      attachButton
      inputField
      sendButton
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)

    HStack {
      Text("input.hint")
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Spacer()
      if let label = selectedModelLabel {
        Text(label)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 18)
    .padding(.bottom, 6)
  }
  .background(.ultraThinMaterial)
  .overlay(
    RoundedRectangle(cornerRadius: 8)
      .stroke(Color.accentColor.opacity(isDragOver ? 0.6 : 0), lineWidth: 2)
      .padding(2)
  )
  .onDrop(of: [UTType.fileURL], isTargeted: $isDragOver) { providers in
    providers.forEach { provider in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url, url.isFileURL else { return }
        DispatchQueue.main.async { addAttachment(from: url) }
      }
    }
    return !providers.isEmpty
  }
  .onAppear { isFocused = true }
}
```

- [ ] **Step 4: Add `attachButton` computed property (below `inputField`)**

```swift
private var attachButton: some View {
  Button(action: openFilePicker) {
    Image(systemName: "paperclip")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(width: 28, height: 28)
  }
  .buttonStyle(.plain)
  .help(String(localized: "input.attach.help"))
}
```

- [ ] **Step 5: Add helper methods (before `selectedModelLabel`)**

```swift
private func openFilePicker() {
  let panel = NSOpenPanel()
  panel.canChooseFiles = true
  panel.canChooseDirectories = false
  panel.allowsMultipleSelection = true
  panel.allowedContentTypes = [.text, .pdf, .image]
  panel.begin { response in
    guard response == .OK else { return }
    panel.urls.forEach { addAttachment(from: $0) }
  }
}

private func addAttachment(from url: URL) {
  do {
    let file = try AttachmentProcessor.makeAttachedFile(url: url)
    pendingAttachments.append(file)
  } catch AttachmentProcessingError.unsupportedType {
    // Silently ignore unsupported types dropped onto the input area.
  } catch {
    let alert = NSAlert()
    alert.messageText = "Could not attach file"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.runModal()
  }
}
```

- [ ] **Step 6: Update the `ChatInputView` initializer call site — `ChatView` will fail to compile until Task 10, but confirm the view itself builds in isolation**

Build (⌘B) — expect one error only in `ChatView.swift` ("missing argument for parameter `pendingAttachments`")

- [ ] **Step 7: Commit**

```bash
git add Chat42/Sources/Views/ChatInputView.swift
git commit -m "feat: add attach button and drag-and-drop to ChatInputView"
```

---

## Task 10: Update ChatView

**Files:**
- Modify: `Chat42/Sources/Views/ChatView.swift`

- [ ] **Step 1: Add `pendingAttachments` state**

Add to `ChatView`'s `@State` declarations:

```swift
@State private var pendingAttachments: [AttachedFile] = []
```

- [ ] **Step 2: Update the `ChatInputView` initializer to pass the binding**

Replace:
```swift
ChatInputView(inputText: $inputText) {
  sendMessage()
}
```

With:
```swift
ChatInputView(inputText: $inputText, pendingAttachments: $pendingAttachments) {
  sendMessage()
}
.environment(state)
```

- [ ] **Step 3: Update `sendMessage()` to pass attachments and clear them**

Replace `sendMessage()`:

```swift
private func sendMessage() {
  let text = inputText
  let attachments = pendingAttachments
  inputText = ""
  pendingAttachments = []
  Task { await state.sendMessage(text, attachments: attachments) }
}
```

- [ ] **Step 4: Build (⌘B) — expect success**

- [ ] **Step 5: Commit**

```bash
git add Chat42/Sources/Views/ChatView.swift
git commit -m "feat: wire pendingAttachments state in ChatView"
```

---

## Task 11: Update MessageBubbleView to show attachment chips

**Files:**
- Modify: `Chat42/Sources/Views/MessageBubbleView.swift`

- [ ] **Step 1: Add attachment chips above the bubble content**

In `bubbleContent`, wrap the existing `ZStack` in a `VStack` that first shows attachment chips. Replace `bubbleContent`:

```swift
private var bubbleContent: some View {
  VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
    if !message.attachments.isEmpty {
      attachmentChips
    }
    ZStack(alignment: isUser ? .bottomTrailing : .bottomLeading) {
      bubbleText
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          isUser ? Color.userBubble : Color.assistantBubble,
          in: bubbleShape
        )
        .overlay(
          bubbleShape
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )

      if message.isStreaming {
        typingIndicator
          .offset(x: isUser ? -10 : 10, y: -6)
      }
    }

    HStack(spacing: 8) {
      Text(message.timestamp.formatted(date: .omitted, time: .shortened))
        .font(.caption2)
        .foregroundStyle(.tertiary)

      if !isUser && !message.content.isEmpty {
        Button {
          copyContent()
        } label: {
          Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            .font(.caption2)
            .foregroundStyle(isCopied ? Color.green : Color.secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(String(localized: "message.copy.help"))
      }
    }
  }
}
```

- [ ] **Step 2: Add the `attachmentChips` computed property (after `bubbleContent`)**

```swift
private var attachmentChips: some View {
  ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 6) {
      ForEach(message.attachments) { attachment in
        AttachmentChipView(name: attachment.name, type: attachment.type)
      }
    }
    .padding(.vertical, 2)
  }
}
```

- [ ] **Step 3: Build (⌘B) — expect success**

- [ ] **Step 4: Commit**

```bash
git add Chat42/Sources/Views/MessageBubbleView.swift
git commit -m "feat: show attachment chips in MessageBubbleView"
```

---

## Task 12: Add localization strings

**Files:**
- Modify: `Chat42/Resources/en.lproj/Localizable.strings`
- Modify: `Chat42/Resources/nl.lproj/Localizable.strings`

- [ ] **Step 1: Add English strings to `en.lproj/Localizable.strings`**

Add under the `/* Input */` section:

```
"input.attach.help" = "Attach file";
```

Add under the `/* App state errors */` section:

```
"error.mlx_no_images" = "MLX does not support image attachments. Use Ollama or Gateway with a vision model.";
```

- [ ] **Step 2: Add Dutch strings to `nl.lproj/Localizable.strings`**

Find the existing `nl.lproj/Localizable.strings` and add the same keys with Dutch values:

```
"input.attach.help" = "Bestand bijvoegen";
"error.mlx_no_images" = "MLX ondersteunt geen afbeeldingsbijlagen. Gebruik Ollama of Gateway met een vision model.";
```

- [ ] **Step 3: Build (⌘B) — expect success**

- [ ] **Step 4: Commit**

```bash
git add Chat42/Resources/en.lproj/Localizable.strings Chat42/Resources/nl.lproj/Localizable.strings
git commit -m "feat: add localization strings for file attachment UI"
```

---

## Task 13: Manual smoke test

- [ ] **Step 1: Run the app in Xcode (⌘R)**

- [ ] **Step 2: Test text file attachment**
  1. Open a conversation with any backend
  2. Click the paperclip button → select a `.swift` or `.txt` file
  3. Verify the chip appears above the input field with the correct icon and filename
  4. Type "Explain this file" and send
  5. Verify the assistant bubble shows the file chip (read-only, no ×)
  6. Verify the assistant responds with relevant content about the file

- [ ] **Step 3: Test drag and drop**
  1. Drag a file from Finder onto the input area
  2. Verify the blue border appears while hovering
  3. Verify the chip is added after dropping
  4. Press × on the chip — verify it is removed

- [ ] **Step 4: Test image attachment (Gateway/Ollama with vision model)**
  1. Attach a `.png` or `.jpg` file
  2. Type "Describe this image" and send
  3. Verify the model responds with a description of the image

- [ ] **Step 5: Test image rejection on MLX**
  1. Switch to MLX backend
  2. Attach an image file and send
  3. Verify the assistant bubble shows the error: "MLX does not support image attachments…"

- [ ] **Step 6: Test PDF attachment**
  1. Attach a `.pdf` file
  2. Ask "Summarize this document"
  3. Verify the model responds with a summary of the PDF content

- [ ] **Step 7: Test send with only an image (no typed text)**
  1. Attach an image with no text in the input field
  2. Verify the Send button is enabled
  3. Send — verify the assistant responds

- [ ] **Step 8: Test canSend state**
  1. With no text and no attachments, verify Send button is disabled
  2. Add an attachment with no text — verify Send becomes enabled
  3. Remove the attachment — verify Send is disabled again
