import Foundation

enum AIBackend: String, Codable, CaseIterable, Hashable {
  case ollama = "Ollama"
  case mlx = "MLX"
  case gateway = "Gateway"

  var systemImage: String {
    switch self {
    case .ollama: return "server.rack"
    case .mlx: return "apple.terminal"
    case .gateway: return "globe"
    }
  }
}

struct OllamaModelInfo: Codable, Hashable, Identifiable {
  var id: String { name }
  let name: String
  let modifiedAt: String?
  let size: Int64?
  let digest: String?

  enum CodingKeys: String, CodingKey {
    case name
    case modifiedAt = "modified_at"
    case size
    case digest
  }

  var displayName: String {
    // "llama3.2:latest" → "llama3.2"
    name.components(separatedBy: ":").first ?? name
  }

  var tag: String {
    name.components(separatedBy: ":").last ?? "latest"
  }

  var sizeFormatted: String {
    guard let size else { return "" }
    let gb = Double(size) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(size) / 1_048_576
    return String(format: "%.0f MB", mb)
  }
}

struct OllamaTagsResponse: Codable {
  let models: [OllamaModelInfo]
}

struct MLXModelInfo: Hashable, Identifiable {
  let id: String
  let name: String
  let repoId: String
  /// Localization key. The blurb is prose and gets translated; `name` is a product
  /// name and deliberately is not.
  let descriptionKey: String

  var description: String {
    String(localized: String.LocalizationValue(descriptionKey))
  }

  static let bundled: [MLXModelInfo] = [
    MLXModelInfo(
      id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
      name: "Llama 3.2 1B (4-bit)",
      repoId: "mlx-community/Llama-3.2-1B-Instruct-4bit",
      descriptionKey: "mlx.model.llama_1b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
      name: "Llama 3.2 3B (4-bit)",
      repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit",
      descriptionKey: "mlx.model.llama_3b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
      name: "Mistral 7B (4-bit)",
      repoId: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
      descriptionKey: "mlx.model.mistral_7b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Phi-3.5-mini-instruct-4bit",
      name: "Phi 3.5 Mini (4-bit)",
      repoId: "mlx-community/Phi-3.5-mini-instruct-4bit",
      descriptionKey: "mlx.model.phi35.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/gemma-2-2b-it-4bit",
      name: "Gemma 2 2B (4-bit)",
      repoId: "mlx-community/gemma-2-2b-it-4bit",
      descriptionKey: "mlx.model.gemma_2b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Llama-3.1-8B-Instruct-4bit",
      name: "Llama 3.1 8B (4-bit)",
      repoId: "mlx-community/Llama-3.1-8B-Instruct-4bit",
      descriptionKey: "mlx.model.llama31_8b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Llama-3.1-70B-Instruct-4bit",
      name: "Llama 3.1 70B (4-bit)",
      repoId: "mlx-community/Llama-3.1-70B-Instruct-4bit",
      descriptionKey: "mlx.model.llama31_70b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Qwen2-7B-Instruct-4bit",
      name: "Qwen 2 7B (4-bit)",
      repoId: "mlx-community/Qwen2-7B-Instruct-4bit",
      descriptionKey: "mlx.model.qwen2_7b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Meta-Llama-3-8B-Instruct-4bit",
      name: "Llama 3 8B (4-bit)",
      repoId: "mlx-community/Meta-Llama-3-8B-Instruct-4bit",
      descriptionKey: "mlx.model.llama3_8b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Meta-Llama-3-70B-Instruct-4bit",
      name: "Llama 3 70B (4-bit)",
      repoId: "mlx-community/Meta-Llama-3-70B-Instruct-4bit",
      descriptionKey: "mlx.model.llama3_70b.desc"
    ),
    MLXModelInfo(
      id: "mlx-community/Phi-3-medium-instruct-4bit",
      name: "Phi 3 Medium (4-bit)",
      repoId: "mlx-community/Phi-3-medium-instruct-4bit",
      descriptionKey: "mlx.model.phi3_medium.desc"
    ),
  ]
}
