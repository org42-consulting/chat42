import Foundation

// MARK: - Errors

enum GatewayError: LocalizedError {
  case unreachable(String)
  case authenticationFailed
  case invalidResponse(Int)
  case apiError(String)
  case decodingError(Error)
  /// The model rejected a request parameter outright (e.g. reasoning-tier models
  /// that refuse any explicit `temperature`). Carries the parameter name.
  case unsupportedParameter(String)
  /// The gateway lists the model but does not route it (404 with no message).
  case modelNotAvailable(String)

  var errorDescription: String? {
    switch self {
    case .unreachable(let url):
      return String(format: String(localized: "error.gateway.unreachable"), url)
    case .authenticationFailed: return String(localized: "error.gateway.auth_failed")
    case .invalidResponse(let code):
      return String(format: String(localized: "error.gateway.invalid_response"), code)
    case .apiError(let msg):
      return String(format: String(localized: "error.gateway.api_error"), msg)
    case .decodingError(let err): return err.localizedDescription
    case .unsupportedParameter(let name):
      return String(format: String(localized: "error.gateway.unsupported_parameter"), name)
    case .modelNotAvailable(let model):
      return String(format: String(localized: "error.gateway.model_unavailable"), model)
    }
  }
}

// MARK: - OpenAI-compatible model list

struct GatewayModelsResponse: Codable {
  let data: [GatewayModelInfo]
}

struct GatewayModelInfo: Codable, Hashable, Identifiable {
  let id: String
  let ownedBy: String?
  let supportsVision: Bool?
  let contextWindow: Int?

  enum CodingKeys: String, CodingKey {
    case id
    case ownedBy = "owned_by"
    case supportsVision = "supports_vision"
    case contextWindow = "context_window"
  }

  /// A human-readable label derived from the raw model id.
  var displayName: String { id }

  /// Whether this model produces images rather than text, and so must be sent to
  /// `/v1/images/generations` instead of `/v1/chat/completions`.
  ///
  /// Classified by id because no gateway field distinguishes them: `gpt-image-1`
  /// and `text-embedding-3-large` both report a zero context window. Getting it
  /// wrong costs a clear error from the endpoint, never a silent failure.
  var isImageGeneration: Bool {
    let name = id.lowercased()
    guard !name.contains("embedding") else { return false }
    return name.contains("image")  // also matches "imagen-*"
  }
}

// MARK: - Chat request/response (OpenAI format)

struct GatewayChatRequest: Encodable {
  let model: String
  let messages: [GatewayChatMessage]
  let stream: Bool
  // Optional so it can be omitted entirely: several model families reject any
  // explicit temperature and 400 the whole request. Synthesized encoding uses
  // encodeIfPresent, so nil drops the key rather than sending null.
  let temperature: Double?
}

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

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(text, forKey: .text)
    try container.encodeIfPresent(imageURL, forKey: .imageURL)
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

struct GatewayChatChunk: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable {
      let content: String?
    }
    let delta: Delta
    let finishReason: String?
    enum CodingKeys: String, CodingKey {
      case delta
      case finishReason = "finish_reason"
    }
  }
  let choices: [Choice]
  let error: GatewayAPIError?

  // An error frame carries no `choices`. Defaulting instead of requiring the key
  // keeps mid-stream errors decodable rather than silently skipped.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    choices = (try? c.decode([Choice].self, forKey: .choices)) ?? []
    error = try? c.decode(GatewayAPIError.self, forKey: .error)
  }

  enum CodingKeys: String, CodingKey { case choices, error }
}

/// The `{"error": {...}}` envelope every OpenAI-compatible gateway returns on failure.
struct GatewayErrorEnvelope: Decodable {
  let error: GatewayAPIError
}

struct GatewayAPIError: Decodable {
  let message: String
  let type: String?
  let code: String?
  let param: String?

  // Decoded leniently: `code` is a string on some gateways and a number on others,
  // and a strict failure here would cost us the message we actually want.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    message = (try? c.decode(String.self, forKey: .message)) ?? ""
    type = try? c.decode(String.self, forKey: .type)
    code = try? c.decode(String.self, forKey: .code)
    param = try? c.decode(String.self, forKey: .param)
  }

  enum CodingKeys: String, CodingKey { case message, type, code, param }
}

// MARK: - Image generation payloads

struct GatewayImageRequest: Encodable {
  let model: String
  let prompt: String
  let n: Int
  let size: String
}

struct GatewayImageResponse: Decodable {
  struct Item: Decodable {
    let b64JSON: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
      case b64JSON = "b64_json"
      case url
    }
  }
  let data: [Item]
}

// MARK: - Failure mapping

/// Turns a non-2xx gateway response into the most actionable error available.
///
/// Free-standing rather than a method on the actor so the classification — which is
/// pure string handling over bodies that differ per provider — can be exercised
/// directly.
enum GatewayFailureMapper {
  static func error(status: Int, body: Data, model: String? = nil) -> GatewayError {
    if status == 401 || status == 403 { return .authenticationFailed }

    let api = (try? JSONDecoder().decode(GatewayErrorEnvelope.self, from: body))?.error
    let raw = String(data: body, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let apiMessage = (api?.message).flatMap { $0.isEmpty ? nil : $0 }
    // Fall back to the raw body only when it is not a recognisable error envelope.
    // Otherwise a message-less envelope would be shown to the user as raw JSON.
    let detail = apiMessage ?? (api == nil ? (raw?.isEmpty == true ? nil : raw) : nil)

    if status == 400, rejectsTemperature(api: api, message: detail) {
      return .unsupportedParameter("temperature")
    }
    if let detail, !detail.isEmpty { return .apiError(detail) }
    // A message-less 404 means the gateway lists the model but does not route it —
    // what every imagen-*/gemini-*-image model on this proxy returns.
    if status == 404 { return .modelNotAvailable(model ?? "") }
    return .invalidResponse(status)
  }

  /// True when a 400 is complaining specifically about `temperature`. Providers word
  /// this at least three ways ("Unsupported value:", "Unsupported parameter:",
  /// "`temperature` is deprecated"), so fall back to the text when `param` is absent.
  static func rejectsTemperature(api: GatewayAPIError?, message: String?) -> Bool {
    if api?.param == "temperature" { return true }
    guard let lower = message?.lowercased(), lower.contains("temperature") else { return false }
    return lower.contains("unsupported") || lower.contains("not supported")
      || lower.contains("does not support") || lower.contains("deprecated")
  }
}

// MARK: - Service

actor GatewayService: ChatBackend {
  var baseURL: String
  var apiKey: String

  init(baseURL: String = "", apiKey: String = "") {
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  func update(baseURL: String, apiKey: String) {
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  // MARK: - List models
  //
  // Doubles as the reachability check. Probing `/v1/models` and then immediately
  // fetching `/v1/models` made every refresh two identical round-trips.

  func fetchModels() async throws -> [GatewayModelInfo] {
    guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/v1/models") else {
      throw GatewayError.unreachable(baseURL)
    }
    var req = URLRequest(url: url, timeoutInterval: 8)
    applyHeaders(to: &req)

    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 || status == 403 { throw GatewayError.authenticationFailed }
    guard (200..<300).contains(status) else {
      if let envelope = try? JSONDecoder().decode(GatewayErrorEnvelope.self, from: data),
        !envelope.error.message.isEmpty
      {
        throw GatewayError.apiError(envelope.error.message)
      }
      throw GatewayError.invalidResponse(status)
    }

    do {
      let decoded = try JSONDecoder().decode(GatewayModelsResponse.self, from: data)
      return decoded.data.sorted { $0.id < $1.id }
    } catch {
      throw GatewayError.decodingError(error)
    }
  }

  // MARK: - Streaming chat (SSE)

  func stream(
    model: String,
    messages: [ChatMessage],
    temperature: Double = 0.7
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          do {
            try await self.streamCompletion(
              model: model, messages: messages, temperature: temperature,
              yielding: continuation)
          } catch GatewayError.unsupportedParameter(let name) where name == "temperature" {
            // Reasoning-tier models across several providers reject any explicit
            // temperature. The request 400'd, so nothing was streamed and retrying
            // without it is safe — better than an error the user cannot act on.
            try await self.streamCompletion(
              model: model, messages: messages, temperature: nil,
              yielding: continuation)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      // Stopping a reply has to tear down the HTTP request too, not just stop
      // reading it — otherwise the gateway keeps generating (and billing).
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Performs one streaming completion request, yielding tokens into `continuation`.
  /// Returns when the stream ends; throws on any transport or API failure.
  private func streamCompletion(
    model: String,
    messages: [ChatMessage],
    temperature: Double?,
    yielding continuation: AsyncThrowingStream<String, Error>.Continuation
  ) async throws {
    guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/v1/chat/completions") else {
      throw GatewayError.unreachable(baseURL)
    }

    let chatMessages = messages.map { msg -> GatewayChatMessage in
      if let images = msg.images, !images.isEmpty {
        var parts: [ContentPart] = []
        if !msg.content.isEmpty { parts.append(.textPart(msg.content)) }
        parts += images.map { ContentPart.imagePart(dataURI: $0) }
        return GatewayChatMessage(role: msg.role.rawValue, content: .parts(parts))
      }
      return GatewayChatMessage(role: msg.role.rawValue, content: .text(msg.content))
    }

    let body = GatewayChatRequest(
      model: model,
      messages: chatMessages,
      stream: true,
      temperature: temperature
    )

    guard let bodyData = try? JSONEncoder().encode(body) else {
      throw GatewayError.apiError("Encoding failed")
    }

    // Reasoning models can think for minutes before the first token arrives; the
    // default 60s would cancel valid work.
    var req = URLRequest(url: url, timeoutInterval: 600)
    req.httpMethod = "POST"
    req.httpBody = bodyData
    applyHeaders(to: &req)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw await failure(status: status, body: bytes)
    }

    // Parse SSE lines: "data: {...}" or "data: [DONE]"
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data: ") else { continue }
      let payload = String(line.dropFirst(6))
      if payload == "[DONE]" { return }
      guard let data = payload.data(using: .utf8),
        let chunk = try? JSONDecoder().decode(GatewayChatChunk.self, from: data)
      else { continue }

      if let apiError = chunk.error, !apiError.message.isEmpty {
        throw GatewayError.apiError(apiError.message)
      }
      if let token = chunk.choices.first?.delta.content {
        continuation.yield(token)
      }
    }
  }

  // MARK: - Image generation

  /// Generates images via `/v1/images/generations`.
  ///
  /// Unlike `chat(...)` this is a single request/response with no streaming, and the
  /// endpoint accepts one prompt with no conversation history — so nothing from the
  /// transcript is sent.
  func generateImage(
    model: String,
    prompt: String,
    size: String = "1024x1024"
  ) async throws -> [Data] {
    guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/v1/images/generations") else {
      throw GatewayError.unreachable(baseURL)
    }

    // Generation routinely takes 30-60s; the default 60s timeout cancels valid work.
    var req = URLRequest(url: url, timeoutInterval: 180)
    req.httpMethod = "POST"
    req.httpBody = try? JSONEncoder().encode(
      GatewayImageRequest(model: model, prompt: prompt, n: 1, size: size))
    applyHeaders(to: &req)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw failure(status: status, data: data, model: model)
    }

    let decoded: GatewayImageResponse
    do {
      decoded = try JSONDecoder().decode(GatewayImageResponse.self, from: data)
    } catch {
      throw GatewayError.decodingError(error)
    }

    var images: [Data] = []
    for item in decoded.data {
      if let b64 = item.b64JSON, let bytes = Data(base64Encoded: b64) {
        images.append(bytes)
      } else if let link = item.url, let remote = URL(string: link) {
        // gpt-image always inlines base64, but other gateways hand back a URL.
        let (fetched, _) = try await URLSession.shared.data(from: remote)
        images.append(fetched)
      }
    }
    guard !images.isEmpty else {
      throw GatewayError.apiError(String(localized: "error.gateway.no_image"))
    }
    return images
  }

  // MARK: - Error mapping

  /// Builds a `GatewayError` from a non-2xx response, preferring the provider's own
  /// message. A bare status code is almost never actionable for the user.
  private func failure(
    status: Int, body: URLSession.AsyncBytes, model: String? = nil
  ) async -> GatewayError {
    if status == 401 || status == 403 { return .authenticationFailed }
    return failure(status: status, data: await drain(body), model: model)
  }

  /// Same mapping for non-streaming responses, which already hold the whole body.
  private func failure(status: Int, data: Data, model: String? = nil) -> GatewayError {
    GatewayFailureMapper.error(status: status, body: data, model: model)
  }

  /// Collects an error response body, tolerating truncation.
  private func drain(_ bytes: URLSession.AsyncBytes) async -> Data {
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count >= 32_768 { break }  // error bodies are small; don't buffer a firehose
      }
    } catch {
      // A truncated body still usually contains the message.
    }
    return data
  }

  // MARK: - Private helpers

  private func applyHeaders(to request: inout URLRequest) {
    if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }
}
