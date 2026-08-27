import Foundation

enum OllamaError: LocalizedError {
  case unreachable(String)
  case invalidResponse
  case apiError(String)
  case decodingError(Error)

  var errorDescription: String? {
    switch self {
    case .unreachable(let url):
      return String(format: String(localized: "error.ollama.unreachable"), url)
    case .invalidResponse:
      return String(localized: "error.ollama.invalid_response")
    case .apiError(let msg):
      return String(format: String(localized: "error.ollama.api_error"), msg)
    case .decodingError(let err):
      return String(format: String(localized: "error.ollama.decoding"), err.localizedDescription)
    }
  }
}

// MARK: - Request/Response types

struct OllamaChatRequest: Codable {
  let model: String
  let messages: [OllamaChatMessage]
  let stream: Bool
  let options: OllamaOptions?
}

struct OllamaChatMessage: Codable {
  let role: String
  let content: String
  let images: [String]?  // raw base64 strings (no data URI prefix)
}

struct OllamaOptions: Codable {
  let temperature: Double?
  let numCtx: Int?

  enum CodingKeys: String, CodingKey {
    case temperature
    case numCtx = "num_ctx"
  }
}

struct OllamaPullRequest: Codable {
  let name: String
  let stream: Bool
}

struct OllamaChatResponse: Codable {
  let model: String
  let message: OllamaChatMessage?
  let done: Bool
  let error: String?
}

// MARK: - Service

actor OllamaService: ChatBackend {
  var baseURL: String
  /// Mirrors the app's context budget into Ollama's `num_ctx`.
  ///
  /// This has to be set, not left to default: Ollama's own default is 2048–4096
  /// depending on version, which silently truncates a long chat or an attached
  /// document even on a model whose real window is far larger.
  var contextTokenLimit: Int

  init(baseURL: String = "http://localhost:11434", contextTokenLimit: Int = 8192) {
    self.baseURL = baseURL
    self.contextTokenLimit = contextTokenLimit
  }

  func updateBaseURL(_ url: String) {
    baseURL = url
  }

  func updateContextTokenLimit(_ limit: Int) {
    contextTokenLimit = limit
  }

  // MARK: - List models
  //
  // Doubles as the reachability check: a caller that wants to know whether Ollama
  // is up wants the model list anyway, and asking twice made every refresh two
  // identical round-trips.
  func fetchModels() async throws -> [OllamaModelInfo] {
    guard let url = URL(string: "\(baseURL)/api/tags") else {
      throw OllamaError.unreachable(baseURL)
    }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "GET"
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw OllamaError.invalidResponse
      }
      let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
      return decoded.models.sorted { $0.name < $1.name }
    } catch let error as OllamaError {
      throw error
    } catch is URLError {
      throw OllamaError.unreachable(baseURL)
    } catch {
      throw OllamaError.decodingError(error)
    }
  }

  // MARK: - Streaming chat
  func stream(
    model: String,
    messages: [ChatMessage],
    temperature: Double
  ) -> AsyncThrowingStream<String, Error> {
    let numCtx = contextTokenLimit
    let base = baseURL
    return AsyncThrowingStream { continuation in
      let task = Task {
        guard let url = URL(string: "\(base)/api/chat") else {
          continuation.finish(throwing: OllamaError.unreachable(base))
          return
        }

        let chatMessages = messages.map { msg -> OllamaChatMessage in
          // Strip the "data:<mime>;base64," prefix — Ollama expects raw base64.
          let base64Images = msg.images?.compactMap { uri -> String? in
            let raw = uri.components(separatedBy: ",").last ?? uri
            return raw.isEmpty ? nil : raw
          }
          return OllamaChatMessage(
            role: msg.role.rawValue,
            content: msg.content,
            images: base64Images?.isEmpty == false ? base64Images : nil
          )
        }

        let requestBody = OllamaChatRequest(
          model: model,
          messages: chatMessages,
          stream: true,
          options: OllamaOptions(temperature: temperature, numCtx: numCtx)
        )

        guard let body = try? JSONEncoder().encode(requestBody) else {
          continuation.finish(throwing: OllamaError.invalidResponse)
          return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Time-to-first-token on a cold model can run to minutes while Ollama
        // pages weights in; the default 60s would cancel valid work.
        request.timeoutInterval = 600

        do {
          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: OllamaError.invalidResponse)
            return
          }
          guard http.statusCode == 200 else {
            throw OllamaError.apiError(
              await Self.errorMessage(from: bytes, status: http.statusCode))
          }

          for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty,
              let data = line.data(using: .utf8)
            else { continue }

            if let parsed = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) {
              if let error = parsed.error {
                continuation.finish(throwing: OllamaError.apiError(error))
                return
              }
              if let token = parsed.message?.content {
                continuation.yield(token)
              }
              if parsed.done {
                continuation.finish()
                return
              }
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Ollama reports a failed chat as a JSON `{"error": "..."}` body rather than a
  /// bare status, and the message is the only actionable part.
  private static func errorMessage(from bytes: URLSession.AsyncBytes, status: Int) async -> String {
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count >= 8_192 { break }
      }
    } catch {
      // A truncated body still usually contains the message.
    }
    struct Envelope: Decodable { let error: String }
    if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      !envelope.error.isEmpty
    {
      return envelope.error
    }
    let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return raw?.isEmpty == false ? raw! : "HTTP \(status)"
  }

  // MARK: - Pull model
  func pullModel(name: String) -> AsyncThrowingStream<PullProgress, Error> {
    let base = baseURL
    return AsyncThrowingStream { continuation in
      let task = Task {
        guard let url = URL(string: "\(base)/api/pull") else {
          continuation.finish(throwing: OllamaError.unreachable(base))
          return
        }

        // Encoded from a struct, not a [String: String] — `stream` must be a JSON
        // boolean; sending the string "true" makes Ollama reject the request.
        let body = try? JSONEncoder().encode(OllamaPullRequest(name: name, stream: true))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
          let (bytes, _) = try await URLSession.shared.bytes(for: request)
          for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
              let progress = try? JSONDecoder().decode(PullProgress.self, from: data)
            else { continue }
            continuation.yield(progress)
            if progress.status == "success" {
              continuation.finish()
              return
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Delete model
  func deleteModel(name: String) async throws {
    guard let url = URL(string: "\(baseURL)/api/delete") else {
      throw OllamaError.unreachable(baseURL)
    }
    let body = try JSONEncoder().encode(["name": name])
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let (_, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw OllamaError.invalidResponse
    }
  }
}

struct PullProgress: Codable {
  let status: String
  let digest: String?
  let total: Int64?
  let completed: Int64?

  var progress: Double {
    guard let total, let completed, total > 0 else { return 0 }
    return Double(completed) / Double(total)
  }
}
