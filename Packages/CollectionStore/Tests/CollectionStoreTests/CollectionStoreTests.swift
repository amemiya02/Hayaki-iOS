import AnkiCore
import CollectionStore
import CollectionTesting
import Foundation
import Testing

@Suite("Collection Store", .timeLimit(.minutes(1)))
struct CollectionStoreTests {
    @Test("Opening a place with no collection creates an empty one; opening it again finds the same collection")
    func firstAndLaterOpen() async throws {
        let folder = try TemporaryFolder()
        let location = CollectionLocation(folder: folder.url.appendingPathComponent("Collection"))

        let first = try await CollectionStore.open(at: location, core: CoreClient(language: "en"))
        #expect(try await first.deckNames() == ["Default"])
        try await first.addDeck(named: "Spanish")
        try await first.close()

        let later = try await CollectionStore.open(at: location, core: CoreClient(language: "en"))
        #expect(try await later.deckNames() == ["Default", "Spanish"])
        try await later.close()
    }

    @Test("Every subscriber hears what a modifying operation changed")
    func changeSignal() async throws {
        try await withTemporaryCollection { store in
            let decks = store.changes()
            let browser = store.changes()

            let deckID = try await store.addDeck(named: "Spanish")
            try await store.addBasicNotes(count: 1, toDeck: deckID)

            var heardByDecks = decks.makeAsyncIterator()
            var heardByBrowser = browser.makeAsyncIterator()
            let deckAdded = try #require(await heardByDecks.next())
            let notesAdded = try #require(await heardByDecks.next())
            #expect(deckAdded.contains(.deck))
            #expect(!deckAdded.contains(.note))
            #expect(notesAdded.isSuperset(of: [.note, .card]))
            #expect(await heardByBrowser.next() == deckAdded)
            #expect(await heardByBrowser.next() == notesAdded)
        }
    }

    @Test("Undo names the last operation, reverts it, and signals what changed back")
    func undoLastOperation() async throws {
        try await withTemporaryCollection { store in
            #expect(try await store.undoableAction() == nil)
            try await store.addDeck(named: "Spanish")
            let changes = store.changes()

            // The label is the core's own, from its "actions-add-deck" string.
            #expect(try await store.undoableAction() == "Add Deck")
            #expect(try await store.undo() == "Add Deck")

            #expect(try await store.deckNames() == ["Default"])
            #expect(try await store.undoableAction() == nil)
            var heard = changes.makeAsyncIterator()
            #expect(await heard.next()?.contains(.deck) == true)
        }
    }

    @Test("Replacing the collection swaps in another one and signals that everything changed")
    func replaceCollection() async throws {
        // Another learner's collection, exported as a collection package.
        let elsewhere = try TemporaryFolder()
        let other = try await CollectionStore.open(
            at: CollectionLocation(folder: elsewhere.url.appendingPathComponent("Other")),
            core: CoreClient(language: "en")
        )
        try await other.addDeck(named: "Japanese")
        let package = elsewhere.url.appendingPathComponent("other.colpkg")
        // Exporting a collection package closes the collection.
        try await other.core.exportCollectionPackage(.with {
            $0.outPath = package.path
            $0.includeMedia = true
        })

        try await withTemporaryCollection { store in
            try await store.addDeck(named: "Spanish")
            let changes = store.changes()

            try await store.replace { core, location in
                try await core.importCollectionPackage(.with {
                    $0.colPath = location.collectionFile.path
                    $0.backupPath = package.path
                    $0.mediaFolder = location.mediaFolder.path
                    $0.mediaDb = location.mediaDatabase.path
                })
            }

            #expect(try await store.deckNames() == ["Default", "Japanese"])
            var heard = changes.makeAsyncIterator()
            #expect(await heard.next() == .everything)
        }
    }
}

@Suite("RWKV daily list", .timeLimit(.minutes(1)))
struct RwkvDailyListTests {
    @Test("The daily-list switch reads false when absent, round-trips, and refreshes study queues")
    func dailyListSwitch() async throws {
        try await withTemporaryCollection { store in
            #expect(try await store.rwkvDailyList() == false)

            let changes = store.changes()
            try await store.setRwkvDailyList(true)
            #expect(try await store.rwkvDailyList() == true)
            var heard = changes.makeAsyncIterator()
            var all: CollectionChange = []
            while !all.contains(.studyQueues), let next = await heard.next() { all.formUnion(next) }
            #expect(all.contains(.studyQueues))

            try await store.setRwkvDailyList(false)
            #expect(try await store.rwkvDailyList() == false)
        }
    }
}
