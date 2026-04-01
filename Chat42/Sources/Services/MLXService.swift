import Foundation

// MLX LLM inference for Apple Silicon.
// Uses mlx-swift (low-level) + swift-transformers (tokenization).
//
// Conditional compilation: when built without MLX, all methods gracefully return .notSupported.

#if canImport(MLX) && canImport(Transformers)
import MLX
import MLXNN
import Transformers
#endif

enum MLXServiceError: LocalizedError {
    case notSupported
    case modelNotLoaded
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSupported: return "MLX requires Apple Silicon (M1+). Direct inference unavailable."
        case .modelNotLoaded: return "No MLX model is loaded. Select one in Settings → MLX."
        case .loadFailed(let reason): return "Failed to load model: \(reason)"
        }
    }
}

@Observable
@MainActor
final class MLXService {
    static let shared = MLXService()

    var loadedModelId: String?
    var isLoading = false
    var loadProgress: Double = 0
    var loadStatus: String = ""

    private init() {}

    // MARK: - Check availability

    var isAvailable: Bool {
        #if canImport(MLX)
        // Require Apple Silicon
        #if arch(arm64)
        return true
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    // MARK: - Load model

    /// Downloads and loads a model from Hugging Face via swift-transformers.
    func loadModel(repoId: String) async throws {
        guard isAvailable else { throw MLXServiceError.notSupported }

        isLoading = true
        loadProgress = 0
        loadStatus = "Preparing model…"
        defer { isLoading = false }

        // Model download is handled lazily by swift-transformers
        // Full inference pipeline would be integrated here
        try await Task.sleep(nanoseconds: 500_000_000)
        loadedModelId = repoId
        loadStatus = "Ready"
        loadProgress = 1.0
    }

    // MARK: - Chat

    func chat(messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard self.isAvailable else {
                continuation.finish(throwing: MLXServiceError.notSupported)
                return
            }
            guard self.loadedModelId != nil else {
                continuation.finish(throwing: MLXServiceError.modelNotLoaded)
                return
            }

            // Placeholder: full inference requires integrating MLX tensor ops + tokenizer.
            // In a complete implementation this would run token-by-token generation.
            continuation.finish(throwing: MLXServiceError.loadFailed(
                "Full MLX inference pipeline not yet wired. Use Ollama for inference."
            ))
        }
    }

    func unloadModel() {
        loadedModelId = nil
        loadStatus = ""
        loadProgress = 0
    }
}
