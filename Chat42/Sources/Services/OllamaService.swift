import Foundation

enum OllamaError: LocalizedError {
  case unreachable(String)
  case invalidResponse
  case apiError(String)
  case decodingError(Error)

  var errorDescription: String? {
    switch self {
    case .unreachable(let url): return "Cannot reach Ollama at \(url). Is it running?"
    case .invalidResponse: return "Invalid response from Ollama"
    case .apiError(let msg): return "Ollama error: \(msg)"
    case .decodingError(let err): return "Decoding error: \(err.localizedDescription)"
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

struct OllamaChatResponse: Codable {
  let model: String
  let message: OllamaChatMessage?
  let done: Bool
  let error: String?
}

// MARK: - Service

actor OllamaService {
  var baseURL: String

  init(baseURL: String = "http://localhost:11434") {
    self.baseURL = baseURL
  }

  func updateBaseURL(_ url: String) {
    baseURL = url
  }

  // MARK: - Ping / health check
  func isReachable() async -> Bool {
    guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
    var req = URLRequest(url: url, timeoutInterval: 3)
    req.httpMethod = "GET"
    do {
      let (_, response) = try await URLSession.shared.data(for: req)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  // MARK: - List models
  func fetchModels() async throws -> [OllamaModelInfo] {
    guard let url = URL(string: "\(baseURL)/api/tags") else {
      throw OllamaError.unreachable(baseURL)
    }
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw OllamaError.invalidResponse
      }
      let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
      return decoded.models.sorted { $0.name < $1.name }
    } catch let error as OllamaError {
      throw error
    } catch let urlError as URLError {
      throw OllamaError.unreachable(baseURL)
    } catch {
      throw OllamaError.decodingError(error)
    }
  }

  // MARK: - Streaming chat
  func chat(
    model: String,
    messages: [ChatMessage],
    temperature: Double = 0.7
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      Task {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
          continuation.finish(throwing: OllamaError.unreachable(self.baseURL))
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
          options: OllamaOptions(temperature: temperature, numCtx: 4096)
        )

        guard let body = try? JSONEncoder().encode(requestBody) else {
          continuation.finish(throwing: OllamaError.invalidResponse)
          return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            continuation.finish(throwing: OllamaError.invalidResponse)
            return
          }

          for try await line in bytes.lines {
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
    }
  }

  // MARK: - Pull model
  func pullModel(name: String) -> AsyncThrowingStream<PullProgress, Error> {
    AsyncThrowingStream { continuation in
      Task {
        guard let url = URL(string: "\(baseURL)/api/pull") else {
          continuation.finish(throwing: OllamaError.unreachable(self.baseURL))
          return
        }

        let body = try? JSONEncoder().encode(["name": name, "stream": "true"])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
          let (bytes, _) = try await URLSession.shared.bytes(for: request)
          for try await line in bytes.lines {
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
