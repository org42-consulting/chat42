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
  /// Approximate download size, from each repo's HuggingFace file list as measured
  /// on 2026-08-28. Shown before downloading so a 40 GB pull is not one unlabelled
  /// click away from a 0.4 GB one. Held as a number rather than baked into the
  /// localized blurb so it renders identically in every language, and stays
  /// approximate on purpose — repos get requantized and re-uploaded.
  let approximateSizeGB: Double

  var description: String {
    String(localized: String.LocalizationValue(descriptionKey))
  }

  /// Uses the same decimal `.file` scale as `MLXService.formattedDiskSize`, so the
  /// estimate and the post-download size are read off one scale rather than
  /// differing by a silent 1024/1000. `isAdaptive` is off to cap the result at three
  /// significant digits ("16.9 GB", "39.7 GB"); the adaptive default renders
  /// "16.87 GB", which reads like a measurement rather than the estimate this is.
  /// Sub-gigabyte entries fall back to MB, so the smallest rung reads "350 MB".
  var formattedApproximateSize: String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.isAdaptive = false
    return formatter.string(fromByteCount: Int64(approximateSizeGB * 1_000_000_000))
  }

  /// Curated `mlx-community` repos, smallest first so the Settings list reads as a
  /// size ladder. Every entry's `config.json` `model_type` must be registered in
  /// MLXLLM's `LLMTypeRegistry` — the app loads through `LLMModelFactory`, so an
  /// unregistered architecture (`qwen3_5`, `gemma4`, `mistral3`, `deepseek_v4`,
  /// `glm4_moe`) downloads gigabytes and then fails at load. Re-check the registry
  /// before adding a model, and bump mlx-swift-examples to reach a newer family.
  static let bundled: [MLXModelInfo] = [
    MLXModelInfo(
      id: "mlx-community/Qwen3-0.6B-4bit",
      name: "Qwen 3 0.6B (4-bit)",
      repoId: "mlx-community/Qwen3-0.6B-4bit",
      descriptionKey: "mlx.model.qwen3_06b.desc",
      approximateSizeGB: 0.35
    ),
    MLXModelInfo(
      id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
      name: "Llama 3.2 1B (4-bit)",
      repoId: "mlx-community/Llama-3.2-1B-Instruct-4bit",
      descriptionKey: "mlx.model.llama_1b.desc",
      approximateSizeGB: 0.71
    ),
    MLXModelInfo(
      id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
      name: "Llama 3.2 3B (4-bit)",
      repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit",
      descriptionKey: "mlx.model.llama_3b.desc",
      approximateSizeGB: 1.82
    ),
    MLXModelInfo(
      id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
      name: "Qwen 3 4B (4-bit)",
      repoId: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
      descriptionKey: "mlx.model.qwen3_4b.desc",
      approximateSizeGB: 2.28
    ),
    MLXModelInfo(
      id: "mlx-community/gemma-3-4b-it-qat-4bit",
      name: "Gemma 3 4B (4-bit QAT)",
      repoId: "mlx-community/gemma-3-4b-it-qat-4bit",
      descriptionKey: "mlx.model.gemma3_4b.desc",
      approximateSizeGB: 3.03
    ),
    MLXModelInfo(
      id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
      name: "Mistral 7B (4-bit)",
      repoId: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
      descriptionKey: "mlx.model.mistral_7b.desc",
      approximateSizeGB: 4.08
    ),
    MLXModelInfo(
      id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
      name: "Qwen 2.5 Coder 7B (4-bit)",
      repoId: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
      descriptionKey: "mlx.model.qwen25_coder_7b.desc",
      approximateSizeGB: 4.3
    ),
    MLXModelInfo(
      id: "mlx-community/Qwen3-8B-4bit",
      name: "Qwen 3 8B (4-bit)",
      repoId: "mlx-community/Qwen3-8B-4bit",
      descriptionKey: "mlx.model.qwen3_8b.desc",
      approximateSizeGB: 4.62
    ),
    MLXModelInfo(
      id: "mlx-community/gemma-3-12b-it-qat-4bit",
      name: "Gemma 3 12B (4-bit QAT)",
      repoId: "mlx-community/gemma-3-12b-it-qat-4bit",
      descriptionKey: "mlx.model.gemma3_12b.desc",
      approximateSizeGB: 8.07
    ),
    MLXModelInfo(
      id: "mlx-community/Qwen3-14B-4bit",
      name: "Qwen 3 14B (4-bit)",
      repoId: "mlx-community/Qwen3-14B-4bit",
      descriptionKey: "mlx.model.qwen3_14b.desc",
      approximateSizeGB: 8.32
    ),
    MLXModelInfo(
      id: "mlx-community/gpt-oss-20b-MXFP4-Q8",
      name: "GPT-OSS 20B (MXFP4)",
      repoId: "mlx-community/gpt-oss-20b-MXFP4-Q8",
      descriptionKey: "mlx.model.gpt_oss_20b.desc",
      approximateSizeGB: 12.1
    ),
    MLXModelInfo(
      id: "mlx-community/gemma-3-27b-it-qat-4bit",
      name: "Gemma 3 27B (4-bit QAT)",
      repoId: "mlx-community/gemma-3-27b-it-qat-4bit",
      descriptionKey: "mlx.model.gemma3_27b.desc",
      approximateSizeGB: 16.87
    ),
    MLXModelInfo(
      id: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
      name: "Qwen 3 30B A3B (4-bit)",
      repoId: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
      descriptionKey: "mlx.model.qwen3_30b_a3b.desc",
      approximateSizeGB: 17.2
    ),
    MLXModelInfo(
      id: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
      name: "Qwen 3 Coder 30B A3B (4-bit)",
      repoId: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
      descriptionKey: "mlx.model.qwen3_coder_30b.desc",
      approximateSizeGB: 17.2
    ),
    MLXModelInfo(
      id: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit",
      name: "DeepSeek R1 Distill 32B (4-bit)",
      repoId: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit",
      descriptionKey: "mlx.model.r1_distill_32b.desc",
      approximateSizeGB: 18.44
    ),
    MLXModelInfo(
      id: "mlx-community/Llama-3.3-70B-Instruct-4bit",
      name: "Llama 3.3 70B (4-bit)",
      repoId: "mlx-community/Llama-3.3-70B-Instruct-4bit",
      descriptionKey: "mlx.model.llama33_70b.desc",
      approximateSizeGB: 39.71
    ),
  ]
}
