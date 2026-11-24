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
    static let weightsName = "rwkv-sm56-weights.int8.bin"
    static let weightsURL = URL(string: "https://raw.githubusercontent.com/JSchoreels/anki/001440b03395f24ffc1714b18ad3d9d4d89d2067/qt/aqt/rwkv_inference/sm56/weights.int8.bin")!
    static let weightsSHA256 = "479b3e2bc6a1c900ba8a4a45d629965c6df2a20cc8ff294583f5aeaeea3b4fdd"
    static let weightsLength = 436_391

    /// Shared by every profile, outside the collection folders.
    public static var weightsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "rwkv", directoryHint: .isDirectory)
    }

    static func isValid(_ data: Data) -> Bool {
        data.count == weightsLength
            && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == weightsSHA256
    }

    /// Downloads the weights here rather than in the core, so the download
    /// never holds the core's worker thread.
    static func ensureWeights() async throws {
        let file = weightsDirectory.appending(path: weightsName)
        if let data = try? Data(contentsOf: file), isValid(data) { return }
        let (data, response) = try await URLSession.shared.data(from: weightsURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, isValid(data) else {
            throw CoreError(kind: .invalidInput, message: "RWKV weights: size or SHA-256 does not match")
        }
        try FileManager.default.createDirectory(at: weightsDirectory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
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
        try await RwkvScheduling.ensureWeights()
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

    /// Called after the collection opens: with the switch on, preparation
    /// starts at once. Study uses the upstream queue until it is ready, so a
    /// failure here only shows in Settings.
    public func prepareRwkvIfEnabled() async {
        guard let status = try? await rwkvStatus(), status.enabled,
              status.state != .ready, status.state != .preparing else { return }
        _ = try? await prepareRwkv()
    }
}
