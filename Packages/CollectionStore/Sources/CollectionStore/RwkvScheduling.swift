import AnkiCore
import AnkiProto
import CryptoKit
import Foundation

/// RWKV scheduling (ADR 0007, Android ADR-0009). The switch is the synced
/// collection config key `hayakiRwkvScheduling`. The core keeps the model
/// state and builds the review queue; the app downloads the weights, starts
/// preparation and shows the status.
public enum RwkvScheduling {
    public static let configKey = "hayakiRwkvScheduling"
    /// With RWKV scheduling on, choose the day's review cards once at the
    /// first study of the day. Absent means false.
    public static let dailyListConfigKey = "hayakiRwkvDailyList"

    /// Shared by every profile, outside the collection folders.
    public static var weightsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "rwkv", directoryHint: .isDirectory)
    }

    static func isValid(_ data: Data, _ weights: Anki_ZzHayaki_RwkvWeights) -> Bool {
        UInt64(data.count) == weights.size
            && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == weights.sha256
    }

    /// Downloads the chosen model's weights here rather than in the core, so
    /// the download never holds the core's worker thread.
    static func ensureWeights(_ weights: Anki_ZzHayaki_RwkvWeights) async throws {
        let file = weightsDirectory.appending(path: weights.fileName)
        // The backend verifies the cached bytes when loading the model.
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           UInt64(size) == weights.size { return }
        guard let url = URL(string: weights.url) else {
            throw CoreError(kind: .invalidInput, message: "RWKV weights: invalid URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, isValid(data, weights) else {
            throw CoreError(kind: .invalidInput, message: "RWKV weights: size or SHA-256 does not match")
        }
        try FileManager.default.createDirectory(at: weightsDirectory, withIntermediateDirectories: true)
        let part = file.appendingPathExtension("part")
        try data.write(to: part)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: file)
        }
    }
}

extension CollectionStore {
    public func rwkvStatus() async throws(CoreError) -> Anki_ZzHayaki_RwkvStatusResponse {
        try await core.rwkvStatus()
    }

    /// Downloads the weights if needed and starts preparing the open
    /// collection in the background.
    @discardableResult
    @MainActor public func prepareRwkv() async throws -> Anki_ZzHayaki_RwkvStatusResponse {
        let status = try await core.rwkvStatus()
        if let current = preparingRwkv, current.model == status.model {
            return try await current.task.value
        }
        let task = Task {
            try await RwkvScheduling.ensureWeights(status.weights)
            return try await core.prepareRwkv(.with { $0.weightsDir = RwkvScheduling.weightsDirectory.path(percentEncoded: false) })
        }
        preparingRwkv = (status.model, task)
        defer { if preparingRwkv?.task == task { preparingRwkv = nil } }
        let response = try await task.value
        signal(.studyQueues)
        return response
    }

    public func setRwkvEnabled(_ enabled: Bool) async throws {
        let request = Anki_Config_SetConfigJsonRequest.with {
            $0.key = RwkvScheduling.configKey
            $0.valueJson = Data((enabled ? "true" : "false").utf8)
            $0.undoable = false
        }
        try await modify(.setConfigJson(request))
        if enabled { try await prepareRwkv() }
    }

    /// Whether RWKV fixes the day's review list at the first study of the day.
    public func rwkvDailyList() async throws -> Bool {
        do {
            let response = try await core.perform(.getConfigJson(.with { $0.val = RwkvScheduling.dailyListConfigKey }))
            return (try? JSONDecoder().decode(Bool.self, from: response.json)) ?? false
        } catch where error.kind == .notFoundError {
            return false
        }
    }

    public func setRwkvDailyList(_ enabled: Bool) async throws {
        let request = Anki_Config_SetConfigJsonRequest.with {
            $0.key = RwkvScheduling.dailyListConfigKey
            $0.valueJson = Data((enabled ? "true" : "false").utf8)
            $0.undoable = false
        }
        try await modify(.setConfigJson(request))
        // A config change carries no study-queue flag, yet the queues and counts depend on it.
        signal(.studyQueues)
    }

    /// Chooses the model, which syncs with the collection. With the switch on,
    /// prepares the new model right after.
    public func setRwkvModel(_ model: Anki_ZzHayaki_RwkvModel) async throws {
        let status = try await core.setRwkvModel(.with { $0.model = model })
        if status.enabled { try await prepareRwkv() }
    }

    public func prepareRwkvIfEnabled() async {
        _ = try? await startRwkvIfNeeded()
    }

    private func startRwkvIfNeeded() async throws -> Anki_ZzHayaki_RwkvStatusResponse {
        let status = try await rwkvStatus()
        if status.enabled && (status.state == .notPrepared || status.state == .failed) {
            return try await prepareRwkv()
        }
        return status
    }

    /// Read a tree with counts after restoration and any replay triggered by the count itself.
    public func dueDeckTree() async throws -> Anki_Decks_DeckTreeNode {
        var status = try await startRwkvIfNeeded()
        var pollDelayMs = 16
        while true {
            try Task.checkCancellation()
            if !status.enabled || status.state == .ready {
                let tree = try await core.deckTree(.with { $0.now = Int64(Date().timeIntervalSince1970) })
                if !status.enabled { return tree }
                status = try await rwkvStatus()
                if status.enabled && status.state == .ready { return tree }
            } else if status.state == .preparing {
                try await Task.sleep(for: .milliseconds(pollDelayMs))
                pollDelayMs = min(pollDelayMs * 2, 250)
                status = try await rwkvStatus()
            } else if status.state == .notPrepared {
                status = try await prepareRwkv()
            } else {
                throw CoreError(kind: .invalidInput, message: status.error)
            }
        }
    }
}
