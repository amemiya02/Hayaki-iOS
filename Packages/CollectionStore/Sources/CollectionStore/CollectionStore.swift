import AnkiCore
import AnkiProto
import Foundation
import Observation
import Synchronization

/// The learner's open collection.
///
/// The store is the only place that knows where the collection lives, and it
/// owns opening, closing and replacing it. Feature models read through `core`
/// and make every change that modifies the collection through `modify(_:)`,
/// which signals the change to every subscriber of `changes()`.
@Observable
public final class CollectionStore: Sendable {
    /// The Core Client the collection is open in. Use it directly for calls
    /// that only read.
    public let core: CoreClient
    public let location: CollectionLocation
    /// Package and sync actions stop accepting new work while the app switches away
    /// from this store or exports a package that could temporarily close it.
    @MainActor private var acceptingProfileWork = true
    @MainActor public var allowsNewProfileWork: Bool {
        get { acceptingProfileWork && !isExportingPackage }
        set { acceptingProfileWork = newValue }
    }
    /// A package export can temporarily close the collection.
    @MainActor public private(set) var isExportingPackage = false

    @MainActor public func beginPackageExport() -> Bool {
        guard allowsNewProfileWork else { return false }
        isExportingPackage = true
        return true
    }

    @MainActor public func endPackageExport() {
        isExportingPackage = false
    }
    private struct Changes {
        var revision: UInt64 = 0
        var subscribers: [UUID: AsyncStream<CollectionChange>.Continuation] = [:]
    }
    private let changeState = Mutex(Changes())

    /// Advances whenever the store signals a change, even with no subscribers.
    public var changeRevision: UInt64 { changeState.withLock { $0.revision } }

    private init(core: CoreClient, location: CollectionLocation) {
        self.core = core
        self.location = location
    }

    /// Opens the collection at `location`, creating an empty one if there is
    /// none yet. The work happens on the Core Client's worker thread.
    public static func open(at location: CollectionLocation, core: CoreClient) async throws(CoreError) -> CollectionStore {
        do {
            // The core creates the collection file but not the media folder,
            // which exporting with media needs.
            try FileManager.default.createDirectory(at: location.mediaFolder, withIntermediateDirectories: true)
        } catch {
            throw CoreError(kind: .ioError, message: error.localizedDescription)
        }
        try await core.openCollection(location.openRequest)
        let store = CollectionStore(core: core, location: location)
        // RWKV scheduling prepares in the background when its switch is on.
        Task { await store.prepareRwkvIfEnabled() }
        return store
    }

    /// Closes the collection. Nothing may use the store afterwards.
    public func close() async throws(CoreError) {
        try await core.closeCollection(.init())
    }

    /// Replaces the collection: closes it, runs `body` (which may overwrite
    /// the files at `location`, for example by importing a collection package
    /// through the core), opens the collection again and signals that
    /// everything changed. The collection is reopened even if `body` throws.
    public func replace(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (_ core: CoreClient, _ location: CollectionLocation) async throws -> Void
    ) async throws {
        try await close()
        var failure: (any Error)?
        do {
            try await body(core, location)
        } catch {
            failure = error
        }
        try await core.openCollection(location.openRequest)
        signal(.everything)
        if let failure { throw failure }
    }

    /// Runs `body`, which hands the open collection to a core operation that
    /// closes it when done (exporting a collection package does), then opens
    /// the collection again and signals that everything changed. The
    /// collection is reopened even if `body` throws, whether or not the
    /// operation got as far as closing it.
    public func reopening(
        isolation: isolated (any Actor)? = #isolation,
        after body: (_ core: CoreClient) async throws -> Void
    ) async throws {
        var failure: (any Error)?
        do {
            try await body(core)
        } catch {
            failure = error
        }
        // Fails harmlessly when the operation already closed it.
        try? await core.closeCollection(.init())
        try await core.openCollection(location.openRequest)
        signal(.everything)
        if let failure { throw failure }
    }

    /// Runs a call that modifies the collection and signals what it changed.
    @discardableResult
    public func modify<Response: CollectionChanging>(_ call: CoreCall<Response>) async throws(CoreError) -> Response {
        let response = try await core.perform(call)
        signal(CollectionChange(response.collectionChanges))
        return response
    }

    /// Checks media and publishes the core's repairs to note references.
    public func checkMedia() async throws(CoreError) -> Anki_Media_CheckMediaResponse {
        let report = try await core.checkMedia()
        // CheckMedia repairs fields and may rebuild queues without returning a change summary.
        signal([.note, .noteText, .browserTable, .studyQueues, .mtime])
        return report
    }

    /// Toggles the mark without overwriting fields edited by another feature.
    @discardableResult
    public func toggleNoteMark(_ noteID: Int64) async throws(CoreError) -> Bool {
        let result = try await core.toggleNoteMark(noteID)
        signal(CollectionChange(result.changes))
        return result.marked
    }

    public func updateSchedulingPreferences(
        _ update: @Sendable @escaping (inout Anki_Config_Preferences.Scheduling) -> Void
    ) async throws(CoreError) {
        let response = try await core.updateSchedulingPreferences(update)
        signal(CollectionChange(response.collectionChanges))
    }

    /// Waits for a long operation that modifies the collection, started with
    /// `core.start(_:)` so it can show progress and be cancelled, and signals
    /// what it changed once it succeeds.
    @discardableResult
    public func modify<Response: CollectionChanging>(_ operation: LongOperation<Response>) async throws(CoreError) -> Response {
        let response = try await operation.result
        signal(CollectionChange(response.collectionChanges))
        return response
    }

    /// The name of the operation `undo()` would revert, in the core's
    /// language, such as "Add Deck"; nil when there is nothing to undo.
    public func undoableAction() async throws(CoreError) -> String? {
        let name = try await core.getUndoStatus().undo
        return name.isEmpty ? nil : name
    }

    /// Reverts the last operation that can be undone, signals what that
    /// changed, and returns the operation's name.
    @discardableResult
    public func undo() async throws(CoreError) -> String {
        try await modify(.undo()).operation
    }

    /// Reverts an offered step if it is still current and publishes its changes.
    public func undo(ifLastStep step: UInt32) async throws(CoreError) -> Bool {
        guard let applied = try await core.undo(ifLastStep: step) else { return false }
        signal(CollectionChange(applied.changes))
        return true
    }

    /// The changes made to the collection from now on, one element per
    /// modifying operation, in order. Each call returns a new subscription;
    /// it ends when the task iterating it is cancelled or the stream is
    /// dropped.
    public func changes() -> AsyncStream<CollectionChange> {
        let (stream, continuation) = AsyncStream<CollectionChange>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.changeState.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        changeState.withLock { $0.subscribers[id] = continuation }
        return stream
    }

    /// Tells every subscriber that the collection changed. `modify(_:)` and
    /// `replace(_:)` signal by themselves; call this only after a change the
    /// core makes without a change summary, such as a sync.
    public func signal(_ change: CollectionChange) {
        guard !change.isEmpty else { return }
        let subscribers = changeState.withLock { state in
            state.revision &+= 1
            return Array(state.subscribers.values)
        }
        for continuation in subscribers {
            continuation.yield(change)
        }
    }
}
