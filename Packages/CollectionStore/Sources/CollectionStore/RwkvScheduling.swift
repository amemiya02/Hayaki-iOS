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
        if let data = try? Data(contentsOf: file), isValid(data, weights) { return }
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
    public func prepareRwkv() async throws -> Anki_ZzHayaki_RwkvStatusResponse {
        try await RwkvScheduling.ensureWeights(try await core.rwkvStatus().weights)
        let response = try await core.prepareRwkv(.with { $0.weightsDir = RwkvScheduling.weightsDirectory.path(percentEncoded: false) })
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

    /// Chooses the model, which syncs with the collection. With the switch on,
    /// prepares the new model right after.
    public func setRwkvModel(_ model: Anki_ZzHayaki_RwkvModel) async throws {
        let status = try await core.setRwkvModel(.with { $0.model = model })
        if status.enabled { try await prepareRwkv() }
    }

    /// Called after the collection opens: with the switch on, preparation
    /// starts at once. Study uses the upstream queue until it is ready, so a
    /// failure here only shows in Settings.
    public func prepareRwkvIfEnabled() async {
        guard let status = try? await rwkvStatus(), status.enabled,
              status.state != .ready, status.state != .preparing else { return }
        _ = try? await prepareRwkv()
    }
}
