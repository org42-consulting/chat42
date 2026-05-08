import Foundation

// MARK: - Errors

enum GatewayError: LocalizedError {
  case unreachable(String)
  case authenticationFailed
  case invalidResponse(Int)
  case apiError(String)
  case decodingError(Error)

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
  let temperature: Double
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
}

struct GatewayAPIError: Decodable {
  let message: String
  let type: String?
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
    guard (200..<300).contains(status) else { throw GatewayError.invalidResponse(status) }

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
        guard !self.baseURL.isEmpty,
          let url = URL(string: "\(self.baseURL)/v1/chat/completions")
        else {
          continuation.finish(throwing: GatewayError.unreachable(self.baseURL))
          return
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
          continuation.finish(throwing: GatewayError.apiError("Encoding failed"))
          return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        self.applyHeaders(to: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
          let (bytes, response) = try await URLSession.shared.bytes(for: req)
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          if status == 401 || status == 403 {
            continuation.finish(throwing: GatewayError.authenticationFailed)
            return
          }
          guard (200..<300).contains(status) else {
            continuation.finish(throwing: GatewayError.invalidResponse(status))
            return
          }

          // Parse SSE lines: "data: {...}" or "data: [DONE]"
          for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
              continuation.finish()
              return
            }
            guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(GatewayChatChunk.self, from: data)
            else { continue }

            if let apiError = chunk.error {
              continuation.finish(throwing: GatewayError.apiError(apiError.message))
              return
            }
            if let token = chunk.choices.first?.delta.content {
              continuation.yield(token)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  // MARK: - Private helpers

  private func applyHeaders(to request: inout URLRequest) {
    if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }
}
