import Foundation
import SwiftUI

/// Failures raised by the send pipeline itself, before any provider is contacted.
enum SendError: LocalizedError {
  case noModel(AIBackend)
  case mlxDoesNotSupportImages
  case imageModelTakesNoAttachments
  case imageModelNeedsPrompt

  var errorDescription: String? {
    switch self {
    case .noModel(.ollama): return String(localized: "error.no_ollama_model")
    case .noModel(.mlx): return String(localized: "error.no_mlx_model")
    case .noModel(.gateway): return String(localized: "error.no_gateway_model")
    case .mlxDoesNotSupportImages: return String(localized: "error.mlx_no_images")
    case .imageModelTakesNoAttachments: return String(localized: "error.image_no_attachments")
    case .imageModelNeedsPrompt: return String(localized: "error.image_no_prompt")
    }
  }
}

@Observable
@MainActor
final class AppState {
  // MARK: - Conversations
  var conversations: [Conversation] = []
  var selectedConversationId: UUID?

  var selectedConversation: Conversation? {
    conversations.first { $0.id == selectedConversationId }
  }

  // MARK: - Models
  var ollamaModels: [OllamaModelInfo] = []
  var selectedOllamaModel: OllamaModelInfo?
  var selectedMLXModel: MLXModelInfo?
  var gatewayModels: [GatewayModelInfo] = []
  var selectedGatewayModel: GatewayModelInfo?
  var activeBackend: AIBackend = .ollama

  var selectedModelName: String {
    switch activeBackend {
    case .ollama: return selectedOllamaModel?.name ?? String(localized: "default.no_model")
    case .mlx: return selectedMLXModel?.name ?? String(localized: "default.no_model")
    case .gateway: return selectedGatewayModel?.id ?? String(localized: "default.no_model")
    }
  }

  // MARK: - State flags
  var isLoadingModels = false
  var ollamaReachable = false
  var gatewayReachable = false
  var isLoadingGatewayModels = false
  var error: String?

  /// One send task per conversation, so a reply streaming into one chat neither
  /// blocks nor is cancelled by activity in another.
  private var activeSendTasks: [UUID: Task<Void, Never>] = [:]

  // MARK: - Settings
  //
  // Everything here is written back to UserDefaults by `applySettings()` /
  // `applyGatewaySettings(...)` and restored in `init()`. The Gateway API key is
  // the exception — it lives in the Keychain, never in defaults.
  private enum DefaultsKey {
    static let ollamaBaseURL = "ollamaBaseURL"
    static let temperature = "temperature"
    static let systemPrompt = "systemPrompt"
    static let gatewayBaseURL = "gatewayBaseURL"
    static let gatewayAPIKey = "gatewayAPIKey"
    static let contextTokenLimit = "contextTokenLimit"
  }

  static let defaultOllamaBaseURL = "http://localhost:11434"
  static let defaultContextTokenLimit = 8192

  var ollamaBaseURL: String = AppState.defaultOllamaBaseURL
  var temperature: Double = 0.7
  var systemPrompt: String = String(localized: "default.system_prompt")
  /// How much conversation history to send. Older turns are dropped once the
  /// estimate exceeds this; it is also mirrored into Ollama's `num_ctx`.
  var contextTokenLimit: Int = AppState.defaultContextTokenLimit

  var gatewayBaseURL: String = ""

  // MARK: - Services
  let ollamaService: OllamaService
  let gatewayService: GatewayService

  init() {
    let defaults = UserDefaults.standard
    let savedOllamaURL =
      defaults.string(forKey: DefaultsKey.ollamaBaseURL) ?? AppState.defaultOllamaBaseURL
    let savedGatewayURL = defaults.string(forKey: DefaultsKey.gatewayBaseURL) ?? ""
    let savedKey = KeychainHelper.load(forKey: DefaultsKey.gatewayAPIKey) ?? ""
    let savedContextLimit =
      (defaults.object(forKey: DefaultsKey.contextTokenLimit) as? Int)
      ?? AppState.defaultContextTokenLimit

    // Both services are `let`, so they have to be assigned before `self` is usable.
    ollamaService = OllamaService(baseURL: savedOllamaURL, contextTokenLimit: savedContextLimit)
    gatewayService = GatewayService(baseURL: savedGatewayURL, apiKey: savedKey)

    ollamaBaseURL = savedOllamaURL
    gatewayBaseURL = savedGatewayURL
    contextTokenLimit = savedContextLimit
    temperature = (defaults.object(forKey: DefaultsKey.temperature) as? Double) ?? temperature
    // Distinguish "never set" from "deliberately cleared" — an empty system prompt
    // is a valid choice and must not fall back to the default text.
    if let savedPrompt = defaults.string(forKey: DefaultsKey.systemPrompt) {
      systemPrompt = savedPrompt
    }

    loadPersistedConversations()
  }

  // MARK: - Conversation management

  @discardableResult
  func newConversation() -> Conversation {
    let conv = Conversation(
      modelName: selectedModelName,
      backend: activeBackend
    )
    if !systemPrompt.isEmpty {
      conv.messages.append(Message(role: .system, content: systemPrompt))
    }
    conversations.insert(conv, at: 0)
    selectedConversationId = conv.id
    scheduleSave()
    return conv
  }

  func deleteConversation(_ conversation: Conversation) {
    activeSendTasks[conversation.id]?.cancel()
    activeSendTasks[conversation.id] = nil
    if selectedConversationId == conversation.id {
      selectedConversationId = conversations.first { $0.id != conversation.id }?.id
    }
    discardStoredImages(in: conversation.messages)
    conversations.removeAll { $0.id == conversation.id }
    scheduleSave()
  }

  /// Empties a conversation, keeping its system prompt.
  func clearConversation(_ conversation: Conversation) {
    stopStreaming(in: conversation)
    let removed = conversation.messages.filter { $0.role != .system }
    discardStoredImages(in: removed)
    conversation.messages = conversation.messages.filter { $0.role == .system }
    conversation.title = ""
    scheduleSave()
  }

  /// Generated images are owned by the app, so they have to be cleaned up with the
  /// messages that reference them or the store grows without bound.
  private func discardStoredImages(in messages: [Message]) {
    for message in messages {
      for attachment in message.attachments {
        if let filename = attachment.storedFilename { ImageStore.delete(filename) }
      }
    }
  }

  /// `visible` must be the exact array the List was built from: when a search filter
  /// is active, `onDelete` reports indices into the filtered rows, not into
  /// `conversations`, and resolving them against the full list deletes the wrong chats.
  func deleteConversations(at offsets: IndexSet, in visible: [Conversation]) {
    let doomed = offsets.filter { $0 < visible.count }.map { visible[$0] }
    for conversation in doomed {
      deleteConversation(conversation)
    }
  }

  func renameConversation(_ conversation: Conversation, title: String) {
    conversation.title = title
    scheduleSave()
  }

  // MARK: - Message actions

  func deleteMessage(_ message: Message, in conversation: Conversation) {
    discardStoredImages(in: [message])
    conversation.messages.removeAll { $0.id == message.id }
    scheduleSave()
  }

  /// Drops the trailing assistant turn and asks the model again from the same point.
  func regenerate(in conversation: Conversation) {
    guard !conversation.isSending else { return }
    // Walk back over the assistant reply (and any error text that followed it).
    while let last = conversation.messages.last, last.role == .assistant {
      discardStoredImages(in: [last])
      conversation.messages.removeLast()
    }
    guard conversation.messages.last?.role == .user else { return }
    beginTurn(in: conversation) { [weak self] in
      await self?.runTurn(in: conversation)
    }
  }

  /// Replaces the text of an earlier user message and re-runs the conversation from
  /// there, discarding everything that followed it.
  func editAndResend(_ message: Message, newText: String, in conversation: Conversation) {
    guard !conversation.isSending,
      message.role == .user,
      let index = conversation.messages.firstIndex(where: { $0.id == message.id })
    else { return }

    let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !message.attachments.isEmpty else { return }

    let discarded = Array(conversation.messages[(index + 1)...])
    discardStoredImages(in: discarded)
    conversation.messages.removeSubrange((index + 1)...)
    message.content = trimmed

    beginTurn(in: conversation) { [weak self] in
      await self?.runTurn(in: conversation)
    }
  }

  /// Renders a conversation as Markdown for export.
  func exportMarkdown(_ conversation: Conversation) -> String {
    var lines = ["# \(conversation.displayTitle)", ""]
    lines.append("*\(conversation.backend.rawValue) · \(conversation.modelName)*")
    lines.append("")
    for message in conversation.messages {
      switch message.role {
      case .system:
        lines.append("> **System:** \(message.content)")
      case .user:
        lines.append("## \(String(localized: "export.role.user"))")
        lines.append(message.contextContent)
      case .assistant:
        lines.append("## \(String(localized: "export.role.assistant"))")
        lines.append(message.content)
      }
      if !message.attachments.isEmpty {
        let names = message.attachments.map(\.name).joined(separator: ", ")
        lines.append("")
        lines.append("*\(String(localized: "export.attachments")): \(names)*")
      }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Gateway model loading

  func refreshGatewayModels() async {
    isLoadingGatewayModels = true
    defer { isLoadingGatewayModels = false }
    do {
      // One request: the model list is also the reachability answer.
      let models = try await gatewayService.fetchModels()
      gatewayReachable = true
      gatewayModels = models
      if selectedGatewayModel == nil
        || !models.contains(where: { $0.id == selectedGatewayModel?.id })
      {
        selectedGatewayModel = models.first
      }
    } catch {
      gatewayReachable = false
      gatewayModels = []
      // A gateway that was simply never configured is not a failure worth an alert.
      if !gatewayBaseURL.isEmpty {
        self.error = error.localizedDescription
      }
    }
  }

  // MARK: - Ollama model loading

  func refreshOllamaModels(reportError: Bool = false) async {
    isLoadingModels = true
    if reportError { error = nil }
    defer { isLoadingModels = false }

    do {
      let models = try await ollamaService.fetchModels()
      ollamaReachable = true
      ollamaModels = models
      if selectedOllamaModel == nil
        || !models.contains(where: { $0.name == selectedOllamaModel?.name })
      {
        selectedOllamaModel = models.first
      }
    } catch OllamaError.unreachable {
      ollamaReachable = false
      ollamaModels = []
      if reportError { error = String(localized: "error.ollama.not_running") }
    } catch {
      ollamaReachable = false
      if reportError { self.error = error.localizedDescription }
    }
  }

  // MARK: - Sending messages

  func sendMessage(_ text: String, attachments: [AttachedFile] = []) {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty || !attachments.isEmpty else { return }

    let conversation = selectedConversation ?? newConversation()
    guard !conversation.isSending else { return }

    beginTurn(in: conversation) { [weak self] in
      guard let self else { return }
      guard self.appendUserMessage(trimmedText, attachments: attachments, to: conversation) else {
        return
      }
      await self.runTurn(in: conversation)
    }
  }

  /// Marks a conversation busy, runs `work`, and clears the busy state afterwards —
  /// including when the task was cancelled, since cancellation lets the body return
  /// normally rather than unwinding.
  private func beginTurn(
    in conversation: Conversation,
    _ work: @escaping @MainActor () async -> Void
  ) {
    let id = conversation.id
    activeSendTasks[id]?.cancel()
    conversation.isSending = true
    activeSendTasks[id] = Task { @MainActor [weak self] in
      await work()
      conversation.isSending = false
      conversation.isGeneratingImage = false
      if let last = conversation.messages.last, last.isStreaming { last.isStreaming = false }
      self?.activeSendTasks[id] = nil
      self?.scheduleSave()
    }
  }

  /// Appends the user's turn. Returns false when the attachments could not be read,
  /// having already written the failure into the transcript.
  private func appendUserMessage(
    _ trimmedText: String, attachments: [AttachedFile], to conversation: Conversation
  ) -> Bool {
    let contextText: String
    let imageDataURIs: [String]
    do {
      (contextText, imageDataURIs) = try AttachmentProcessor.process(attachments)
    } catch {
      appendError(error.localizedDescription, to: conversation)
      return false
    }

    if activeBackend == .mlx && !imageDataURIs.isEmpty {
      appendError(SendError.mlxDoesNotSupportImages.localizedDescription, to: conversation)
      return false
    }

    // Auto-title from first user message.
    if conversation.messages.filter({ $0.role == .user }).isEmpty {
      let titleSource = trimmedText.isEmpty ? (attachments.first?.name ?? "") : trimmedText
      let words = titleSource.split(separator: " ").prefix(6).joined(separator: " ")
      conversation.title = String(words)
    }

    let messageAttachments = attachments.map {
      MessageAttachment(id: $0.id, name: $0.name, type: $0.type)
    }
    conversation.messages.append(
      Message(
        role: .user,
        content: trimmedText,
        attachments: messageAttachments,
        contextText: contextText,
        imageDataURIs: imageDataURIs
      ))
    conversation.updatedAt = .now
    return true
  }

  /// Runs one model turn against whatever `conversation.messages` currently ends
  /// with. Used by the initial send, by regenerate, and by edit-and-resend.
  private func runTurn(in conversation: Conversation) async {
    // Record what actually served this turn. The values captured at creation time
    // are stale whenever the model list had not loaded yet, or the user switched.
    conversation.modelName = selectedModelName
    conversation.backend = activeBackend

    let assistantMessage = Message(role: .assistant, content: "", isStreaming: true)
    conversation.messages.append(assistantMessage)
    defer { assistantMessage.isStreaming = false }

    do {
      // Image models speak a different endpoint and take no conversation history,
      // so they bypass the context-building and streaming path entirely.
      if activeBackend == .gateway, selectedGatewayModel?.isImageGeneration == true {
        let prompt =
          conversation.messages
          .last(where: { $0.role == .user })?.content ?? ""
        let attachments =
          conversation.messages
          .last(where: { $0.role == .user })?.attachments ?? []
        try await generateImage(
          prompt: prompt, attachmentCount: attachments.count, into: assistantMessage,
          in: conversation)
        return
      }

      let (service, model) = try resolveBackend()
      let context = ContextBuilder.build(
        from: conversation.messages,
        excluding: assistantMessage,
        tokenLimit: contextTokenLimit
      )

      let stream = await service.stream(
        model: model, messages: context, temperature: temperature)

      // Tokens are batched into ~20 updates a second rather than published one at
      // a time. Each mutation of `content` re-evaluates the bubble and re-runs the
      // scroll animation, so publishing per token made the cost of drawing a reply
      // grow with its length.
      var pending = ""
      var lastFlush = ContinuousClock.now
      func flush() {
        guard !pending.isEmpty else { return }
        assistantMessage.content += pending
        pending = ""
        lastFlush = ContinuousClock.now
      }
      defer { flush() }

      for try await token in stream {
        try Task.checkCancellation()
        pending += token
        if ContinuousClock.now - lastFlush >= .milliseconds(50) { flush() }
      }
    } catch is CancellationError {
      // Cancelled by user — keep partial response.
    } catch {
      assistantMessage.content = String(
        format: String(localized: "error.generic"), error.localizedDescription)
      assistantMessage.isError = true
    }
  }

  /// Picks the service and model id for the active backend.
  private func resolveBackend() throws -> (ChatBackend, String) {
    switch activeBackend {
    case .ollama:
      guard let model = selectedOllamaModel else { throw SendError.noModel(.ollama) }
      return (ollamaService, model.name)
    case .mlx:
      let mlx = MLXService.shared
      guard let loaded = mlx.loadedModelId else { throw SendError.noModel(.mlx) }
      return (mlx, loaded)
    case .gateway:
      guard let model = selectedGatewayModel else { throw SendError.noModel(.gateway) }
      return (gatewayService, model.id)
    }
  }

  private func appendError(_ message: String, to conversation: Conversation) {
    conversation.messages.append(
      Message(
        role: .assistant,
        content: String(format: String(localized: "error.generic"), message),
        isError: true))
  }

  /// Runs one image generation and attaches the result to `message`.
  private func generateImage(
    prompt: String, attachmentCount: Int, into message: Message, in conversation: Conversation
  ) async throws {
    guard let model = selectedGatewayModel else { throw SendError.noModel(.gateway) }
    // Editing an existing image is a different endpoint (/v1/images/edits).
    guard attachmentCount == 0 else { throw SendError.imageModelTakesNoAttachments }
    guard !prompt.isEmpty else { throw SendError.imageModelNeedsPrompt }

    conversation.isGeneratingImage = true
    defer { conversation.isGeneratingImage = false }

    let images = try await gatewayService.generateImage(model: model.id, prompt: prompt)
    try Task.checkCancellation()

    message.attachments = try images.map { data in
      MessageAttachment(
        id: UUID(),
        name: Self.imageFilename(for: prompt),
        type: .image,
        storedFilename: try ImageStore.save(data)
      )
    }
  }

  /// A readable default for the save panel, derived from the prompt.
  static func imageFilename(for prompt: String) -> String {
    let filtered =
      prompt
      .lowercased()
      .split(separator: " ").prefix(5)
      .joined(separator: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }

    // Collapse and trim the separators left behind by stripped punctuation.
    // Checking `isEmpty` on the filtered string alone was not enough: a prompt of
    // pure punctuation reduces to "-", which is not empty and produced "-.png".
    let slug =
      filtered
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")

    return (slug.isEmpty ? "image" : slug) + ".png"
  }

  func stopStreaming(in conversation: Conversation) {
    activeSendTasks[conversation.id]?.cancel()
    activeSendTasks[conversation.id] = nil
    conversation.isSending = false
    conversation.isGeneratingImage = false
    if let msg = conversation.messages.last, msg.isStreaming {
      msg.isStreaming = false
    }
  }

  // MARK: - Settings sync

  func applySettings() async {
    let defaults = UserDefaults.standard
    defaults.set(ollamaBaseURL, forKey: DefaultsKey.ollamaBaseURL)
    defaults.set(temperature, forKey: DefaultsKey.temperature)
    defaults.set(systemPrompt, forKey: DefaultsKey.systemPrompt)
    defaults.set(contextTokenLimit, forKey: DefaultsKey.contextTokenLimit)

    await ollamaService.updateBaseURL(ollamaBaseURL)
    await ollamaService.updateContextTokenLimit(contextTokenLimit)
    await refreshOllamaModels(reportError: true)
  }

  func applyGatewaySettings(baseURL: String, apiKey: String) async {
    gatewayBaseURL = baseURL
    UserDefaults.standard.set(baseURL, forKey: DefaultsKey.gatewayBaseURL)
    if !KeychainHelper.save(apiKey, forKey: DefaultsKey.gatewayAPIKey) {
      error = String(localized: "error.keychain_write_failed")
    }
    await gatewayService.update(baseURL: baseURL, apiKey: apiKey)
    await refreshGatewayModels()
  }

  // MARK: - Persistence

  private var saveTask: Task<Void, Never>?
  /// Persistence failures are reported once per session; a full disk would
  /// otherwise raise an alert after every streamed token batch.
  private var hasReportedSaveFailure = false

  /// Coalesces the burst of saves a single turn produces into one write, performed
  /// off the main actor.
  func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await self?.saveNow()
    }
  }

  /// Writes immediately. Called on quit, where there is no time to wait out the
  /// coalescing window.
  func saveNow() async {
    saveTask?.cancel()
    saveTask = nil
    let dtos = conversations.map(ConversationDTO.init)
    do {
      let data = try JSONEncoder().encode(dtos)
      try await ConversationStore.shared.write(data)
      hasReportedSaveFailure = false
    } catch {
      guard !hasReportedSaveFailure else { return }
      hasReportedSaveFailure = true
      self.error = String(
        format: String(localized: "error.persist_failed"), error.localizedDescription)
    }
  }

  private func loadPersistedConversations() {
    guard let data = ConversationStore.shared.readSynchronously(),
      let dtos = try? JSONDecoder().decode([ConversationDTO].self, from: data)
    else { return }
    conversations = dtos.map { $0.toConversation() }
    selectedConversationId = conversations.first?.id
  }
}

/// Serialises conversation writes off the main actor.
///
/// Encoding still happens on the main actor (the model objects are not `Sendable`),
/// but the file write — which was blocking the UI on every turn — does not.
actor ConversationStore {
  static let shared = ConversationStore()

  nonisolated var url: URL {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Chat42/conversations.json")
  }

  func write(_ data: Data) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Atomic, so a crash or a full disk mid-write cannot leave a truncated file
    // that fails to decode on the next launch — which would read as "all my
    // conversations are gone".
    try data.write(to: url, options: .atomic)
  }

  nonisolated func readSynchronously() -> Data? {
    try? Data(contentsOf: url)
  }
}
