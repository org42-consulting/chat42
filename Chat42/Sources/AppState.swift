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

  /// Conversations in the order the sidebar shows them: most recently active first.
  ///
  /// Sorting on `updatedAt` rather than insertion order — the field was already
  /// maintained and persisted but never read, so a chat replied to minutes ago sank
  /// below ones abandoned weeks earlier.
  var conversationsByRecency: [Conversation] {
    Conversation.byRecency(conversations)
  }

  // MARK: - Prompt presets
  var presets: [PromptPreset] = []

  func preset(id: UUID?) -> PromptPreset? {
    guard let id else { return nil }
    return presets.first { $0.id == id }
  }

  func savePreset(_ preset: PromptPreset) {
    if let index = presets.firstIndex(where: { $0.id == preset.id }) {
      presets[index] = preset
    } else {
      presets.append(preset)
    }
    PresetStore.save(presets)
  }

  func deletePreset(_ preset: PromptPreset) {
    presets.removeAll { $0.id == preset.id }
    PresetStore.save(presets)
  }

  // MARK: - Focus requests
  //
  // Menu commands live in the App scene and cannot reach a view's `@FocusState`
  // directly. Bumping a counter the view observes is the smallest bridge that does
  // not leak view state upward.
  var searchFocusRequest = 0
  var composerFocusRequest = 0

  // MARK: - Models
  var ollamaModels: [OllamaModelInfo] = []
  var selectedOllamaModel: OllamaModelInfo?
  var selectedMLXModel: MLXModelInfo?
  var gatewayModels: [GatewayModelInfo] = []
  var selectedGatewayModel: GatewayModelInfo?
  /// Persisted, so the app reopens on the backend that was last in use rather than
  /// always resetting to Ollama.
  var activeBackend: AIBackend = .ollama {
    didSet {
      guard activeBackend != oldValue else { return }
      UserDefaults.standard.set(activeBackend.rawValue, forKey: DefaultsKey.activeBackend)
    }
  }

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
    static let activeBackend = "activeBackend"
    static let gatewayPricePerMillion = "gatewayPricePerMillion"
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

  /// Price per million tokens for the gateway, in whatever currency the user
  /// thinks in. Zero means "unset", and the cost readout stays hidden rather than
  /// inventing a number — pricing is per-model, per-provider, and changes.
  var gatewayPricePerMillion: Double = 0

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
    gatewayPricePerMillion =
      (defaults.object(forKey: DefaultsKey.gatewayPricePerMillion) as? Double) ?? 0
    if let raw = defaults.string(forKey: DefaultsKey.activeBackend),
      let restored = AIBackend(rawValue: raw)
    {
      activeBackend = restored
    }
    // Distinguish "never set" from "deliberately cleared" — an empty system prompt
    // is a valid choice and must not fall back to the default text.
    if let savedPrompt = defaults.string(forKey: DefaultsKey.systemPrompt) {
      systemPrompt = savedPrompt
    }

    loadPersistedConversations()
    loadPresets()
  }

  /// Seeds a small starter set once, so the feature is discoverable, while still
  /// letting someone who deletes them all keep an empty list.
  private func loadPresets() {
    presets = PresetStore.load()
    if presets.isEmpty && !PresetStore.hasSeeded {
      presets = PromptPreset.starters
      PresetStore.save(presets)
    }
    PresetStore.hasSeeded = true
  }

  // MARK: - Conversation management

  @discardableResult
  func newConversation(preset: PromptPreset? = nil) -> Conversation {
    // A preset can pin where it runs. Applied before the conversation records its
    // model, so the transcript names the model that will actually serve it.
    if let preset {
      if let backend = preset.backend { activeBackend = backend }
      if let modelName = preset.modelName { selectModel(named: modelName) }
      if let temperature = preset.temperature { self.temperature = temperature }
    }

    let conv = Conversation(
      modelName: selectedModelName,
      backend: activeBackend,
      presetId: preset?.id
    )
    let instructions = preset?.systemPrompt ?? systemPrompt
    if !instructions.isEmpty {
      conv.messages.append(Message(role: .system, content: instructions))
    }
    conversations.insert(conv, at: 0)
    selectedConversationId = conv.id
    scheduleSave()
    return conv
  }

  /// Selects a model by name on the active backend, if it is available.
  private func selectModel(named name: String) {
    switch activeBackend {
    case .ollama:
      if let match = ollamaModels.first(where: { $0.name == name }) { selectedOllamaModel = match }
    case .gateway:
      if let match = gatewayModels.first(where: { $0.id == name }) { selectedGatewayModel = match }
    case .mlx:
      if let match = MLXModelInfo.bundled.first(where: { $0.repoId == name || $0.name == name }) {
        selectedMLXModel = match
      }
    }
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
  ///
  /// `override` names a model explicitly — "retry with a different model" — instead
  /// of using whatever is selected right now.
  private func runTurn(in conversation: Conversation, using override: ModelRef? = nil) async {
    let primary: ModelRef
    do {
      primary = try override ?? currentModelRef()
    } catch {
      appendError(error.localizedDescription, to: conversation)
      return
    }

    // Context is built before the placeholders are appended, so both columns of a
    // comparison see exactly the same question.
    let context = ContextBuilder.build(
      from: conversation.messages,
      pinned: conversation.pinnedDocuments,
      excluding: nil,
      tokenLimit: contextTokenLimit
    )

    // A comparison runs the same context on two models concurrently. An explicit
    // override means the user asked for one specific model, so it wins.
    if override == nil, let secondary = conversation.compareWith, secondary != primary {
      await runComparison(
        in: conversation, context: context, primary: primary, secondary: secondary)
      return
    }

    // Record what actually served this turn. The values captured at creation time
    // are stale whenever the model list had not loaded yet, or the user switched.
    conversation.modelName = primary.model
    conversation.backend = primary.backend

    let assistantMessage = Message(
      role: .assistant, content: "", isStreaming: true, modelRef: primary)
    conversation.messages.append(assistantMessage)
    await stream(into: assistantMessage, using: primary, context: context, in: conversation)
    conversation.updatedAt = .now
  }

  /// Answers one question on two models at once, tagging both replies with a shared
  /// group id so the transcript can render them as columns.
  private func runComparison(
    in conversation: Conversation, context: [ChatMessage],
    primary: ModelRef, secondary: ModelRef
  ) async {
    let groupId = UUID()
    let left = Message(
      role: .assistant, content: "", isStreaming: true,
      modelRef: primary, comparisonGroupId: groupId)
    let right = Message(
      role: .assistant, content: "", isStreaming: true,
      modelRef: secondary, comparisonGroupId: groupId)
    conversation.messages.append(left)
    conversation.messages.append(right)

    conversation.modelName = primary.model
    conversation.backend = primary.backend

    // Concurrently, not sequentially: waiting for a local model to finish before
    // starting the remote one would double the time to see both answers.
    //
    // Two main-actor `Task`s rather than `async let`. Both replies are non-Sendable
    // `Message` objects owned by the main actor, and `async let` is treated as
    // concurrent execution — so it demands they be sent across an isolation
    // boundary, which they cannot safely be. Staying on the main actor costs
    // nothing here: the work is waiting on network streams, and the two interleave
    // at their suspension points.
    let leftTask = Task { @MainActor in
      await self.stream(into: left, using: primary, context: context, in: conversation)
    }
    let rightTask = Task { @MainActor in
      await self.stream(into: right, using: secondary, context: context, in: conversation)
    }
    _ = await leftTask.value
    _ = await rightTask.value

    conversation.updatedAt = .now
  }

  /// Streams one reply into `message`.
  private func stream(
    into message: Message, using ref: ModelRef, context: [ChatMessage],
    in conversation: Conversation
  ) async {
    defer { message.isStreaming = false }

    do {
      // Image models speak a different endpoint and take no conversation history,
      // so they bypass the streaming path entirely.
      if ref.backend == .gateway, isImageModel(ref) {
        let lastUser = conversation.messages.last(where: { $0.role == .user })
        try await generateImage(
          prompt: lastUser?.content ?? "",
          attachmentCount: lastUser?.attachments.count ?? 0,
          into: message, in: conversation)
        return
      }

      let stream = await service(for: ref.backend).stream(
        model: ref.model, messages: context, temperature: temperature)

      // Tokens are batched into ~20 updates a second rather than published one at
      // a time. Each mutation of `content` re-evaluates the bubble and re-runs the
      // scroll animation, so publishing per token made the cost of drawing a reply
      // grow with its length.
      var pending = ""
      var lastFlush = ContinuousClock.now
      func flush() {
        guard !pending.isEmpty else { return }
        message.content += pending
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
      message.content = String(
        format: String(localized: "error.generic"), error.localizedDescription)
      message.isError = true
    }
  }

  /// The model the current selection resolves to.
  private func currentModelRef() throws -> ModelRef {
    switch activeBackend {
    case .ollama:
      guard let model = selectedOllamaModel else { throw SendError.noModel(.ollama) }
      return ModelRef(backend: .ollama, model: model.name)
    case .mlx:
      guard let loaded = MLXService.shared.loadedModelId else { throw SendError.noModel(.mlx) }
      return ModelRef(backend: .mlx, model: loaded)
    case .gateway:
      guard let model = selectedGatewayModel else { throw SendError.noModel(.gateway) }
      return ModelRef(backend: .gateway, model: model.id)
    }
  }

  private func service(for backend: AIBackend) -> ChatBackend {
    switch backend {
    case .ollama: return ollamaService
    case .mlx: return MLXService.shared
    case .gateway: return gatewayService
    }
  }

  private func isImageModel(_ ref: ModelRef) -> Bool {
    guard ref.backend == .gateway else { return false }
    return gatewayModels.first { $0.id == ref.model }?.isImageGeneration ?? false
  }

  /// Every model that could serve a turn right now, for the comparison and
  /// "retry with" pickers. Image models are excluded — they answer a prompt with a
  /// picture, which is not a comparable reply.
  var availableModels: [ModelRef] {
    var refs = ollamaModels.map { ModelRef(backend: .ollama, model: $0.name) }
    if let loaded = MLXService.shared.loadedModelId {
      refs.append(ModelRef(backend: .mlx, model: loaded))
    }
    refs +=
      gatewayModels
      .filter { !$0.isImageGeneration }
      .map { ModelRef(backend: .gateway, model: $0.id) }
    return refs
  }

  // MARK: - Retry and comparison

  /// Re-asks the last question on a specific model, keeping the previous reply.
  func retry(in conversation: Conversation, using ref: ModelRef) {
    guard !conversation.isSending else { return }
    // Trailing assistant turns are dropped so the retry answers the same question,
    // rather than being read as a reply to the previous answer.
    while let last = conversation.messages.last, last.role == .assistant {
      discardStoredImages(in: [last])
      conversation.messages.removeLast()
    }
    guard conversation.messages.last?.role == .user else { return }
    beginTurn(in: conversation) { [weak self] in
      await self?.runTurn(in: conversation, using: ref)
    }
  }

  func setComparison(_ ref: ModelRef?, in conversation: Conversation) {
    conversation.compareWith = ref
    scheduleSave()
  }

  // MARK: - Pinned documents

  func pinDocument(_ file: AttachedFile, to conversation: Conversation) throws {
    let (text, images) = try AttachmentProcessor.process([file])
    // An image has no text to pin; there is nothing to keep in context for it.
    guard images.isEmpty, !text.isEmpty else {
      throw AttachmentProcessingError.unsupportedType(file.name)
    }
    conversation.pinnedDocuments.append(
      PinnedDocument(name: file.name, text: text, byteCount: file.data.count))
    scheduleSave()
  }

  func unpinDocument(_ document: PinnedDocument, from conversation: Conversation) {
    conversation.pinnedDocuments.removeAll { $0.id == document.id }
    scheduleSave()
  }

  // MARK: - Context usage

  func contextUsage(for conversation: Conversation)
    -> (used: Int, limit: Int, isTrimming: Bool)
  {
    ContextBuilder.usage(for: conversation, tokenLimit: contextTokenLimit)
  }

  /// Estimated spend for a conversation, or nil when no price is configured.
  ///
  /// Deliberately nil rather than zero when unset: gateway pricing is per-model and
  /// changes, so the app has no basis to guess one and showing a made-up number
  /// would be worse than showing none.
  func estimatedCost(for conversation: Conversation) -> String? {
    guard gatewayPricePerMillion > 0, conversation.backend == .gateway else { return nil }
    let tokens = conversation.messages.reduce(0) {
      $0 + ContextBuilder.estimatedTokens($1.contextContent)
    }
    let cost = Double(tokens) / 1_000_000 * gatewayPricePerMillion
    return String(format: "%.3f", cost)
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
    defaults.set(gatewayPricePerMillion, forKey: DefaultsKey.gatewayPricePerMillion)

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
