import Foundation
import SwiftUI

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
  var isSending = false
  var error: String?

  private var activeSendTask: Task<Void, Never>?

  // MARK: - Settings
  var ollamaBaseURL: String = "http://localhost:11434"
  var temperature: Double = 0.7
  var systemPrompt: String = String(localized: "default.system_prompt")
  var showTokenCount: Bool = false

  // Gateway settings (URL stored in UserDefaults, key in Keychain)
  var gatewayBaseURL: String = ""
  // API key is not stored here — always read/write via KeychainHelper directly

  // MARK: - Services
  let ollamaService: OllamaService
  let gatewayService: GatewayService

  init() {
    ollamaService = OllamaService(baseURL: "http://localhost:11434")
    let savedURL = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? ""
    let savedKey = KeychainHelper.load(forKey: "gatewayAPIKey") ?? ""
    gatewayService = GatewayService(baseURL: savedURL, apiKey: savedKey)
    gatewayBaseURL = savedURL
    loadPersistedConversations()
  }

  // MARK: - Conversation management

  func newConversation() {
    let conv = Conversation(
      modelName: selectedModelName,
      backend: activeBackend
    )
    if !systemPrompt.isEmpty {
      conv.messages.append(Message(role: .system, content: systemPrompt))
    }
    conversations.insert(conv, at: 0)
    selectedConversationId = conv.id
  }

  func deleteConversation(_ conversation: Conversation) {
    if selectedConversationId == conversation.id {
      selectedConversationId = conversations.first { $0.id != conversation.id }?.id
    }
    conversations.removeAll { $0.id == conversation.id }
    persistConversations()
  }

  func deleteConversations(at offsets: IndexSet) {
    let toDelete = offsets.map { conversations[$0] }
    toDelete.forEach { deleteConversation($0) }
  }

  func renameConversation(_ conversation: Conversation, title: String) {
    conversation.title = title
    persistConversations()
  }

  // MARK: - Gateway model loading

  func refreshGatewayModels() async {
    isLoadingGatewayModels = true
    defer { isLoadingGatewayModels = false }
    do {
      gatewayReachable = await gatewayService.isReachable()
      guard gatewayReachable else {
        gatewayModels = []
        return
      }
      let models = try await gatewayService.fetchModels()
      gatewayModels = models
      if selectedGatewayModel == nil
        || !models.contains(where: { $0.id == selectedGatewayModel?.id })
      {
        selectedGatewayModel = models.first
      }
    } catch {
      self.error = error.localizedDescription
      gatewayModels = []
    }
  }

  // MARK: - Ollama model loading

  func refreshOllamaModels(reportError: Bool = false) async {
    isLoadingModels = true
    if reportError { error = nil }
    defer { isLoadingModels = false }

    do {
      ollamaReachable = await ollamaService.isReachable()
      guard ollamaReachable else {
        if reportError { error = String(localized: "error.ollama.not_running") }
        ollamaModels = []
        return
      }
      let models = try await ollamaService.fetchModels()
      ollamaModels = models
      if selectedOllamaModel == nil
        || !models.contains(where: { $0.name == selectedOllamaModel?.name })
      {
        selectedOllamaModel = models.first
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: - Sending messages

  func sendMessage(_ text: String) async {
    activeSendTask?.cancel()
    activeSendTask = Task { [weak self] in
      await self?.performSendMessage(text)
    }
  }

  private func performSendMessage(_ text: String) async {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    if selectedConversation == nil {
      newConversation()
    }
    guard let conversation = selectedConversation else { return }

    // Auto-title from first user message
    if conversation.messages.filter({ $0.role == .user }).isEmpty {
      let words = text.split(separator: " ").prefix(6).joined(separator: " ")
      conversation.title = words.isEmpty ? "New Chat" : String(words)
    }

    let userMessage = Message(role: .user, content: text)
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
      let contextMessages = conversation.messages
        .filter { $0.role != .assistant || $0 !== assistantMessage }
        .map { ChatMessage(role: $0.role, content: $0.content) }

      switch activeBackend {
      case .ollama:
        guard let model = selectedOllamaModel else {
          assistantMessage.content = String(localized: "error.no_ollama_model")
          return
        }
        let stream = await ollamaService.chat(
          model: model.name,
          messages: contextMessages,
          temperature: temperature
        )
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
        let stream = await gatewayService.chat(
          model: model.id,
          messages: contextMessages,
          temperature: temperature
        )
        for try await token in stream {
          try Task.checkCancellation()
          assistantMessage.content += token
        }
      }
    } catch is CancellationError {
      // Cancelled by the user; keep partial response as-is.
    } catch {
      assistantMessage.content = String(
        format: String(localized: "error.generic"), error.localizedDescription)
    }
  }

  func stopStreaming() {
    activeSendTask?.cancel()
    activeSendTask = nil
    isSending = false
    if let msg = selectedConversation?.messages.last, msg.isStreaming {
      msg.isStreaming = false
    }
  }

  // MARK: - Settings sync

  func applySettings() async {
    await ollamaService.updateBaseURL(ollamaBaseURL)
    await refreshOllamaModels(reportError: true)
  }

  func applyGatewaySettings(baseURL: String, apiKey: String) async {
    gatewayBaseURL = baseURL
    UserDefaults.standard.set(baseURL, forKey: "gatewayBaseURL")
    KeychainHelper.save(apiKey, forKey: "gatewayAPIKey")
    await gatewayService.update(baseURL: baseURL, apiKey: apiKey)
    await refreshGatewayModels()
  }

  // MARK: - Persistence

  private var storageURL: URL {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Chat42/conversations.json")
  }

  func persistConversations() {
    do {
      let dtos = conversations.map(ConversationDTO.init)
      let data = try JSONEncoder().encode(dtos)
      let dir = storageURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try data.write(to: storageURL)
    } catch {
      print("Persist error: \(error)")
    }
  }

  private func loadPersistedConversations() {
    guard FileManager.default.fileExists(atPath: storageURL.path),
      let data = try? Data(contentsOf: storageURL),
      let dtos = try? JSONDecoder().decode([ConversationDTO].self, from: data)
    else { return }
    conversations = dtos.map { $0.toConversation() }
    selectedConversationId = conversations.first?.id
  }
}
