import Foundation

// MLX model management for Apple Silicon.
// Downloads models directly from the Hugging Face HTTP API using URLSession.
// MLX tensor inference requires arm64 and is guarded with #if arch(arm64).

#if arch(arm64)
  // @preconcurrency: MLX's model types predate Sendable annotations. The app keeps
  // them confined to the generation task rather than passing them across actors.
  @preconcurrency import MLXLLM
  @preconcurrency import MLXLMCommon
#endif

// MARK: - Errors

enum MLXServiceError: LocalizedError {
  case notSupported
  case modelNotLoaded
  case modelNotDownloaded
  case loadFailed(String)
  case noFilesFound
  case unsafeArchivePath(String)

  var errorDescription: String? {
    switch self {
    case .notSupported: return String(localized: "error.mlx.not_supported")
    case .modelNotLoaded: return String(localized: "error.mlx.not_loaded")
    case .modelNotDownloaded: return String(localized: "error.mlx.not_downloaded")
    case .loadFailed(let r):
      return String(format: String(localized: "error.mlx.load_failed"), r)
    case .noFilesFound: return String(localized: "error.mlx.no_files")
    case .unsafeArchivePath(let path):
      return String(format: String(localized: "error.mlx.unsafe_path"), path)
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
final class MLXService: ChatBackend {
  static let shared = MLXService()

  var downloadStates: [String: MLXDownloadState] = [:]
  var loadedModelId: String?
  var isLoading = false
  var loadStatus: String = ""

  private(set) var modelURLs: [String: URL] = [:]
  private static let urlsDefaultsKey = "mlx.downloadedModelURLs"
  private static let lastLoadedKey = "mlx.lastLoadedModelId"
  private static let autoLoadKey = "mlx.autoLoadLastModel"

  /// Whether to restore the last loaded model at launch.
  ///
  /// Defaults to on: without it, every launch began with no model loaded and a trip
  /// through Settings before the local backend could answer anything. It is a
  /// preference rather than unconditional because loading pulls gigabytes into
  /// memory, which not everyone wants on every launch.
  var autoLoadLastModel: Bool {
    didSet { UserDefaults.standard.set(autoLoadLastModel, forKey: Self.autoLoadKey) }
  }

  /// The model to restore, if any. Read once at launch by `autoLoadIfEnabled()`.
  private(set) var lastLoadedModelId: String?

  /// In-flight downloads, so a multi-gigabyte pull started by mistake can be
  /// stopped without quitting the app.
  private var downloadTasks: [String: Task<Void, Never>] = [:]

  #if arch(arm64)
    private var container: ModelContainer?
  #endif

  private init() {
    // `object(forKey:)` rather than `bool(forKey:)` so an unset preference reads as
    // the default rather than as false.
    autoLoadLastModel =
      (UserDefaults.standard.object(forKey: Self.autoLoadKey) as? Bool) ?? true
    lastLoadedModelId = UserDefaults.standard.string(forKey: Self.lastLoadedKey)
    restoreDownloadedModels()
  }

  /// Reloads the model that was in use when the app last quit.
  ///
  /// Called once at launch. Silent on failure: a model that has since been deleted
  /// or a weights file that no longer parses should leave the app usable, not raise
  /// an alert before the window is even on screen.
  func autoLoadIfEnabled() async {
    guard autoLoadLastModel,
      isAvailable,
      loadedModelId == nil,
      let repoId = lastLoadedModelId,
      isDownloaded(repoId: repoId)
    else { return }
    try? await loadModel(repoId: repoId)
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
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
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
  func downloadModel(repoId: String) {
    guard !(downloadStates[repoId]?.isDownloading ?? false) else { return }
    guard !isDownloaded(repoId: repoId) else { return }

    downloadStates[repoId] = .downloading(progress: 0)
    downloadTasks[repoId] = Task { [weak self] in
      await self?.performDownload(repoId: repoId)
      self?.downloadTasks[repoId] = nil
    }
  }

  func cancelDownload(repoId: String) {
    downloadTasks[repoId]?.cancel()
    downloadTasks[repoId] = nil
    // Partial files are left in place deliberately: every file is written to a
    // temporary location and only moved into the model directory once complete, so
    // what remains on disk is whole files and resuming skips them.
    downloadStates[repoId] = isDownloaded(repoId: repoId) ? .downloaded : .notDownloaded
  }

  private func performDownload(repoId: String) async {
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
        try Task.checkCancellation()
        // Keep the repository's own layout. Flattening to the last path component
        // made `original/model.safetensors` overwrite `model.safetensors`, which
        // silently corrupts any repo that ships more than one weights directory.
        let dest = try Self.destination(for: file.name, in: localDir)
        if !FileManager.default.fileExists(atPath: dest.path) {
          try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
          let fileBase = doneBytes
          let fileSize = file.size
          try await hfDownloadFile(repoId: repoId, path: file.name, to: dest) {
            [weak self] fraction in
            let progress: Double =
              totalBytes > 0
              ? (Double(fileBase) + Double(fileSize) * fraction) / Double(totalBytes)
              : fraction
            await MainActor.run { [weak self] in
              guard self?.downloadStates[repoId]?.isDownloading == true else { return }
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
    } catch is CancellationError {
      downloadStates[repoId] = isDownloaded(repoId: repoId) ? .downloaded : .notDownloaded
    } catch {
      downloadStates[repoId] = .failed(error.localizedDescription)
    }
  }

  /// Resolves a repository-relative path inside `root`, refusing anything that
  /// escapes it. The file list comes off the network, so `../../` in a name has to
  /// be treated as hostile rather than as a path.
  static func destination(for relativePath: String, in root: URL) throws -> URL {
    let components = relativePath.split(separator: "/").map(String.init)
    guard !components.isEmpty,
      !components.contains(".."),
      !components.contains("."),
      !relativePath.hasPrefix("/")
    else {
      throw MLXServiceError.unsafeArchivePath(relativePath)
    }
    let resolved = components.reduce(root) { $0.appendingPathComponent($1) }
    guard resolved.path.hasPrefix(root.path) else {
      throw MLXServiceError.unsafeArchivePath(relativePath)
    }
    return resolved
  }

  // MARK: - HuggingFace API helpers

  struct HFFile {
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
    let handle = DownloadHandle()
    let tempURL: URL = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let delegate = HFDownloadProgressDelegate(
          onProgress: onProgress, continuation: continuation)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        handle.attach(task)
        task.resume()
      }
    } onCancel: {
      handle.cancel()
    }
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tempURL, to: dest)
  }

  // MARK: - Delete

  func deleteModel(repoId: String) {
    cancelDownload(repoId: repoId)
    if let url = modelURLs[repoId] { try? FileManager.default.removeItem(at: url) }
    modelURLs.removeValue(forKey: repoId)
    downloadStates[repoId] = .notDownloaded
    removePersisted(for: repoId)
    if lastLoadedModelId == repoId {
      lastLoadedModelId = nil
      UserDefaults.standard.removeObject(forKey: Self.lastLoadedKey)
    }
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
            self?.loadStatus = String(
              format: String(localized: "mlx.status.loading"),
              Int(progress.fractionCompleted * 100))
          }
        }
        container = loaded
        loadedModelId = repoId
        lastLoadedModelId = repoId
        UserDefaults.standard.set(repoId, forKey: Self.lastLoadedKey)
        loadStatus = String(localized: "mlx.status.ready")
      } catch {
        loadStatus = ""
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

  /// `model` is accepted for `ChatBackend` conformance but unused: MLX generates
  /// from whichever container is currently loaded, and `AppState` guards on that.
  func stream(
    model: String,
    messages: [ChatMessage],
    temperature: Double
  ) -> AsyncThrowingStream<String, Error> {
    #if arch(arm64)
      guard isAvailable else {
        return AsyncThrowingStream { $0.finish(throwing: MLXServiceError.notSupported) }
      }
      guard let container else {
        return AsyncThrowingStream { $0.finish(throwing: MLXServiceError.modelNotLoaded) }
      }

      let temperature = Float(temperature)

      return AsyncThrowingStream { continuation in
        let task = Task.detached {
          do {
            try await container.perform { context in
              // MLX's `Chat.Message` and `GenerateParameters` are not Sendable, so
              // they are built here rather than captured from the main actor —
              // everything crossing into this closure (`messages`, `temperature`)
              // is a value type of our own.
              let chat: [Chat.Message] = messages.map { msg in
                switch msg.role {
                case .user: return .user(msg.content)
                case .assistant: return .assistant(msg.content)
                case .system: return .system(msg.content)
                }
              }
              let params = GenerateParameters(temperature: temperature)
              let input = try await context.processor.prepare(input: UserInput(chat: chat))
              let cache = context.model.newCache(parameters: params)
              for await item in try MLXLMCommon.generate(
                input: input, cache: cache, parameters: params, context: context)
              {
                // Stopping a reply has to stop the tensor work too, not just stop
                // reading from it — generation holds the GPU until it returns.
                try Task.checkCancellation()
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
        continuation.onTermination = { _ in task.cancel() }
      }
    #else
      return AsyncThrowingStream { $0.finish(throwing: MLXServiceError.notSupported) }
    #endif
  }
}

// MARK: - Download progress delegate

/// Lets a Swift-concurrency cancellation reach the underlying `URLSessionTask`,
/// including when it arrives before the task has been created.
private final class DownloadHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionDownloadTask?
  private var isCancelled = false

  func attach(_ task: URLSessionDownloadTask) {
    lock.lock()
    defer { lock.unlock() }
    if isCancelled {
      task.cancel()
    } else {
      self.task = task
    }
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    isCancelled = true
    task?.cancel()
  }
}

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
    // URLSession deletes the temp file after this method returns — it has to be
    // relocated here. Moving rather than copying: a copy meant every byte of a
    // multi-gigabyte weights file was written twice before it reached the model
    // directory.
    let moved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.moveItem(at: location, to: moved)
      continuation?.resume(returning: moved)
    } catch {
      continuation?.resume(throwing: error)
    }
    continuation = nil
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // Last callback for every task, success or failure. A delegate session retains
    // its delegate until invalidated, so without this both leak for the lifetime of
    // the process — once per downloaded model file.
    defer { session.finishTasksAndInvalidate() }
    guard let error, !completed else { return }
    completed = true
    continuation?.resume(throwing: error)
    continuation = nil
  }
}
