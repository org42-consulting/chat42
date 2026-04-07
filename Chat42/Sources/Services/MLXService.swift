import Foundation

// MLX model management for Apple Silicon.
// Downloads models directly from the Hugging Face HTTP API using URLSession.
// MLX tensor inference requires arm64 and is guarded with #if arch(arm64).

#if arch(arm64)
  import MLXLLM
  import MLXLMCommon
#endif

// MARK: - Errors

enum MLXServiceError: LocalizedError {
  case notSupported
  case modelNotLoaded
  case modelNotDownloaded
  case loadFailed(String)
  case noFilesFound

  var errorDescription: String? {
    switch self {
    case .notSupported: return "MLX requires Apple Silicon (M1+). Direct inference unavailable."
    case .modelNotLoaded: return "No MLX model is loaded. Select one in Settings → MLX."
    case .modelNotDownloaded: return "Model not downloaded. Download it first in Settings → MLX."
    case .loadFailed(let r): return "Failed to load model: \(r)"
    case .noFilesFound: return "No model files found in repository."
    }
  }
}

// MARK: - Per-model download state

enum MLXDownloadState: Equatable {
  case notDownloaded
  case downloading(progress: Double)
  case downloaded
  case failed(String)

  var isDownloading: Bool {
    if case .downloading = self { return true }
    return false
  }
}

// MARK: - Service

@Observable
@MainActor
final class MLXService {
  static let shared = MLXService()

  var downloadStates: [String: MLXDownloadState] = [:]
  var loadedModelId: String?
  var isLoading = false
  var loadStatus: String = ""

  private(set) var modelURLs: [String: URL] = [:]
  private static let urlsDefaultsKey = "mlx.downloadedModelURLs"

  #if arch(arm64)
    private var container: ModelContainer?
  #endif

  private init() {
    restoreDownloadedModels()
  }

  // MARK: - Availability

  var isAvailable: Bool {
    #if arch(arm64)
      return true
    #else
      return false
    #endif
  }

  // MARK: - Disk utilities

  func isDownloaded(repoId: String) -> Bool { modelURLs[repoId] != nil }

  func formattedDiskSize(for repoId: String) -> String? {
    guard let url = modelURLs[repoId] else { return nil }
    let bytes = directorySize(url)
    guard bytes > 0 else { return nil }
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
  }

  private func modelDirectory(for repoId: String) -> URL {
    let safe = repoId.replacingOccurrences(of: "/", with: "__")
    return FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Chat42/MLXModels/\(safe)", isDirectory: true)
  }

  private func directorySize(_ url: URL) -> Int64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
      )
    else { return 0 }
    return (enumerator.allObjects as? [URL])?.reduce(0) {
      $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    } ?? 0
  }

  // MARK: - Persistence

  private func restoreDownloadedModels() {
    let saved =
      UserDefaults.standard.dictionary(forKey: Self.urlsDefaultsKey) as? [String: String] ?? [:]
    for (repoId, path) in saved {
      let url = URL(fileURLWithPath: path)
      if FileManager.default.fileExists(atPath: url.path) {
        modelURLs[repoId] = url
        downloadStates[repoId] = .downloaded
      }
    }
    for model in MLXModelInfo.bundled where downloadStates[model.repoId] == nil {
      downloadStates[model.repoId] = .notDownloaded
    }
  }

  private func persist(_ url: URL, for repoId: String) {
    var d =
      UserDefaults.standard.dictionary(forKey: Self.urlsDefaultsKey) as? [String: String] ?? [:]
    d[repoId] = url.path
    UserDefaults.standard.set(d, forKey: Self.urlsDefaultsKey)
  }

  private func removePersisted(for repoId: String) {
    var d =
      UserDefaults.standard.dictionary(forKey: Self.urlsDefaultsKey) as? [String: String] ?? [:]
    d.removeValue(forKey: repoId)
    UserDefaults.standard.set(d, forKey: Self.urlsDefaultsKey)
  }

  // MARK: - Download

  /// Downloads a model from Hugging Face using the HF REST API + URLSession.
  func downloadModel(repoId: String) async {
    guard !(downloadStates[repoId]?.isDownloading ?? false) else { return }
    guard !isDownloaded(repoId: repoId) else { return }

    downloadStates[repoId] = .downloading(progress: 0)

    do {
      let files = try await hfFileList(repoId: repoId)
      let wanted = files.filter {
        ["json", "safetensors", "gguf", "model", "txt"]
          .contains(URL(fileURLWithPath: $0.name).pathExtension)
      }
      guard !wanted.isEmpty else { throw MLXServiceError.noFilesFound }

      let localDir = modelDirectory(for: repoId)
      try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

      let totalBytes = wanted.reduce(0) { $0 + $1.size }
      var doneBytes: Int64 = 0

      for file in wanted {
        let filename = file.name.components(separatedBy: "/").last ?? file.name
        let dest = localDir.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: dest.path) {
          let fileBase = doneBytes
          let fileSize = file.size
          try await hfDownloadFile(repoId: repoId, path: file.name, to: dest) {
            [weak self] fraction in
            let progress: Double =
              totalBytes > 0
              ? (Double(fileBase) + Double(fileSize) * fraction) / Double(totalBytes)
              : fraction
            await MainActor.run { [weak self] in
              self?.downloadStates[repoId] = .downloading(progress: min(progress, 1.0))
            }
          }
        }
        doneBytes += file.size
        let progress = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0
        downloadStates[repoId] = .downloading(progress: progress)
      }

      modelURLs[repoId] = localDir
      downloadStates[repoId] = .downloaded
      persist(localDir, for: repoId)
    } catch {
      downloadStates[repoId] = .failed(error.localizedDescription)
    }
  }

  // MARK: - HuggingFace API helpers

  private struct HFFile {
    let name: String
    let size: Int64
  }

  private func hfFileList(repoId: String) async throws -> [HFFile] {
    guard let url = URL(string: "https://huggingface.co/api/models/\(repoId)") else {
      throw URLError(.badURL)
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }
    struct APIResponse: Codable {
      struct Sibling: Codable {
        let rfilename: String
        let size: Int64?
      }
      let siblings: [Sibling]
    }
    let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
    return decoded.siblings.map { HFFile(name: $0.rfilename, size: $0.size ?? 0) }
  }

  nonisolated private func hfDownloadFile(
    repoId: String, path: String, to dest: URL,
    onProgress: @escaping @Sendable (Double) async -> Void = { _ in }
  ) async throws {
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    guard let url = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(encoded)") else {
      return
    }

    // URLSession.shared does not fire per-task download delegate callbacks.
    // A dedicated session with a session-level delegate is required.
    let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
      let delegate = HFDownloadProgressDelegate(onProgress: onProgress, continuation: continuation)
      let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
      session.downloadTask(with: url).resume()
    }
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tempURL, to: dest)
  }

  // MARK: - Delete

  func deleteModel(repoId: String) {
    if let url = modelURLs[repoId] { try? FileManager.default.removeItem(at: url) }
    modelURLs.removeValue(forKey: repoId)
    downloadStates[repoId] = .notDownloaded
    removePersisted(for: repoId)
    if loadedModelId == repoId { unloadModel() }
  }

  // MARK: - Load / Unload

  func loadModel(repoId: String) async throws {
    guard isAvailable else { throw MLXServiceError.notSupported }
    guard let localURL = modelURLs[repoId] else { throw MLXServiceError.modelNotDownloaded }

    isLoading = true
    loadStatus = String(localized: "mlx.status.preparing")
    defer { isLoading = false }

    #if arch(arm64)
      do {
        let config = ModelConfiguration(directory: localURL)
        let loaded = try await LLMModelFactory.shared.loadContainer(configuration: config) {
          [weak self] progress in
          Task { @MainActor [weak self] in
            self?.loadStatus = "Loading… \(Int(progress.fractionCompleted * 100))%"
          }
        }
        container = loaded
        loadedModelId = repoId
        loadStatus = String(localized: "mlx.status.ready")
      } catch {
        throw MLXServiceError.loadFailed(error.localizedDescription)
      }
    #endif
  }

  func unloadModel() {
    #if arch(arm64)
      container = nil
    #endif
    loadedModelId = nil
    loadStatus = ""
  }

  // MARK: - Chat

  func chat(messages: [ChatMessage], temperature: Float = 0.7) -> AsyncThrowingStream<String, Error>
  {
    #if arch(arm64)
      guard isAvailable else {
        return AsyncThrowingStream { $0.finish(throwing: MLXServiceError.notSupported) }
      }
      guard let container else {
        return AsyncThrowingStream { $0.finish(throwing: MLXServiceError.modelNotLoaded) }
      }

      let chatMessages: [Chat.Message] = messages.compactMap { msg in
        switch msg.role {
        case .user: return .user(msg.content)
        case .assistant: return .assistant(msg.content)
        case .system: return .system(msg.content)
        }
      }
      let params = GenerateParameters(temperature: temperature)

      return AsyncThrowingStream { continuation in
        Task.detached {
          do {
            try await container.perform { context in
              let input = try await context.processor.prepare(
                input: UserInput(chat: chatMessages)
              )
              let cache = context.model.newCache(parameters: params)
              for await item in try MLXLMCommon.generate(
                input: input, cache: cache, parameters: params, context: context)
              {
                if let chunk = item.chunk {
                  continuation.yield(chunk)
                }
              }
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
      }
    #else
      return AsyncThrowingStream { $0.finish(throwing: MLXServiceError.notSupported) }
    #endif
  }
}

// MARK: - Download progress delegate

private final class HFDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let onProgress: @Sendable (Double) async -> Void
  private var continuation: CheckedContinuation<URL, Error>?
  private var completed = false

  init(
    onProgress: @escaping @Sendable (Double) async -> Void,
    continuation: CheckedContinuation<URL, Error>
  ) {
    self.onProgress = onProgress
    self.continuation = continuation
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    Task { await self.onProgress(fraction) }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard !completed else { return }
    completed = true
    // URLSession deletes the temp file after this method returns — must copy it first.
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.copyItem(at: location, to: copy)
      continuation?.resume(returning: copy)
    } catch {
      continuation?.resume(throwing: error)
    }
    continuation = nil
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error, !completed else { return }
    completed = true
    continuation?.resume(throwing: error)
    continuation = nil
  }
}
