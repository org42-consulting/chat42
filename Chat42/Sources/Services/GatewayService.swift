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

  enum CodingKeys: String, CodingKey {
    case id
    case ownedBy = "owned_by"
  }

  /// A human-readable label derived from the raw model id.
  var displayName: String { id }
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

// MARK: - Service

actor GatewayService {
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

  // MARK: - Health / reachability

  func isReachable() async -> Bool {
    guard let url = URL(string: "\(baseURL)/v1/models") else { return false }
    var req = URLRequest(url: url, timeoutInterval: 4)
    applyHeaders(to: &req)
    do {
      let (_, response) = try await URLSession.shared.data(for: req)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return (200..<300).contains(status)
    } catch { return false }
  }

  // MARK: - List models

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

  func chat(
    model: String,
    messages: [ChatMessage],
    temperature: Double = 0.7
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      Task {
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

    var req = URLRequest(url: url)
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

  // MARK: - Error mapping

  /// Builds a `GatewayError` from a non-2xx response, preferring the provider's own
  /// message. A bare status code is almost never actionable for the user.
  private func failure(status: Int, body: URLSession.AsyncBytes) async -> GatewayError {
    if status == 401 || status == 403 { return .authenticationFailed }

    let (api, raw) = await readErrorBody(body)
    let detail = (api?.message).flatMap { $0.isEmpty ? nil : $0 } ?? raw

    if status == 400, rejectsTemperature(api: api, message: detail) {
      return .unsupportedParameter("temperature")
    }
    if let detail, !detail.isEmpty { return .apiError(detail) }
    return .invalidResponse(status)
  }

  /// True when a 400 is complaining specifically about `temperature`. Providers word
  /// this at least three ways ("Unsupported value:", "Unsupported parameter:",
  /// "`temperature` is deprecated"), so fall back to the text when `param` is absent.
  private func rejectsTemperature(api: GatewayAPIError?, message: String?) -> Bool {
    if api?.param == "temperature" { return true }
    guard let lower = message?.lowercased(), lower.contains("temperature") else { return false }
    return lower.contains("unsupported") || lower.contains("not supported")
      || lower.contains("does not support") || lower.contains("deprecated")
  }

  /// Drains an error response body and decodes it, tolerating truncation and
  /// non-JSON payloads (some proxies return plain text or HTML).
  private func readErrorBody(
    _ bytes: URLSession.AsyncBytes
  ) async -> (api: GatewayAPIError?, raw: String?) {
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count >= 32_768 { break }  // error bodies are small; don't buffer a firehose
      }
    } catch {
      // A truncated body still usually contains the message.
    }
    guard !data.isEmpty else { return (nil, nil) }
    let envelope = try? JSONDecoder().decode(GatewayErrorEnvelope.self, from: data)
    let raw = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (envelope?.error, (raw?.isEmpty ?? true) ? nil : raw)
  }

  // MARK: - Private helpers

  private func applyHeaders(to request: inout URLRequest) {
    if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }
}
