import AnkiCore
import AnkiProto
import CollectionStore
import Foundation
import Observation

/// One deck in the deck list, with today's counts and its child decks.
public struct DeckNode: Identifiable, Equatable, Sendable {
    public let id: Int64
    /// The deck's own name, without its parents' names.
    public let name: String
    /// The deck's name with its parents' names, as Anki stores it, such as
    /// "Languages::Japanese".
    public let fullName: String
    public let counts: DeckCounts
    /// Whether the learner collapsed this deck, hiding its child decks.
    public internal(set) var isCollapsed: Bool
    /// Whether this is a filtered deck, which borrows cards from other decks.
    public let isFiltered: Bool
    public internal(set) var children: [DeckNode]
    /// All cards in the deck and its child decks, whatever their state.
    public let totalCards: Int

    init(_ node: Anki_Decks_DeckTreeNode, parentName: String? = nil) {
        id = node.deckID
        name = node.name
        fullName = parentName.map { "\($0)::\(node.name)" } ?? node.name
        counts = DeckCounts(
            new: Int(node.newCount),
            learning: Int(node.learnCount),
            due: Int(node.reviewCount)
        )
        isCollapsed = node.collapsed
        isFiltered = node.filtered
        children = node.children.map { [fullName] child in DeckNode(child, parentName: fullName) }
        totalCards = Int(node.totalIncludingChildren)
    }
}

/// How many cards of a deck, including its child decks, can be studied today,
/// as the core reports them after applying the deck's daily limits.
public struct DeckCounts: Equatable, Sendable {
    public let new: Int
    public let learning: Int
    public let due: Int

    public init(new: Int, learning: Int, due: Int) {
        self.new = new
        self.learning = learning
        self.due = due
    }

    public var total: Int { new + learning + due }
    public var isEmpty: Bool { total == 0 }
}

/// The deck list: every deck as a nested list with today's counts.
@MainActor
@Observable
public final class DeckListModel {
    public enum State: Equatable {
        case loading
        case loaded
        case failed(message: String)
    }

    public private(set) var state: State = .loading
    public internal(set) var decks: [DeckNode] = []
    /// Answers recorded since the current study day began.
    public private(set) var studiedToday = 0
    private(set) var currentDeckID: DeckNode.ID?

    /// New, learning and due cards left today over all decks. Summing the
    /// top-level decks avoids double-counting subdecks or using the capped
    /// aggregate from the core's root node.
    public var dueToday: Int { today.total }

    /// Today's new, learning and due cards over all decks, for the Today
    /// card. Summing the top-level decks avoids double-counting subdecks.
    public var today: DeckCounts {
        DeckCounts(
            new: decks.reduce(0) { $0 + $1.counts.new },
            learning: decks.reduce(0) { $0 + $1.counts.learning },
            due: decks.reduce(0) { $0 + $1.counts.due }
        )
    }

    /// The decks Study All goes through, one after another: every top-level
    /// deck with cards left today, in list order. The core's queue is always
    /// one deck and its subdecks, so the top-level decks together cover the
    /// whole collection; a collection of just the Default deck studies it.
    public var studyAllDecks: [DeckNode] {
        decks.filter { !$0.counts.isEmpty }
    }

    /// The deck Study All opens after the learner closes `deckID`: the next
    /// deck with cards left once `deckID` is finished, or nil when the
    /// learner closed it early or nothing is left.
    public func nextStudyAllDeck(after deckID: DeckNode.ID) -> DeckNode? {
        if let closed = deck(deckID), !closed.counts.isEmpty { return nil }
        return studyAllDecks.first
    }

    /// Whether the collection has no cards at all, as on first launch, so
    /// the screen offers to import a package instead of an empty deck list.
    public var hasNoCards: Bool {
        state == .loaded && decks.allSatisfy { $0.totalCards == 0 }
    }

    @ObservationIgnored let store: CollectionStore

    /// Changes after which the decks or their counts may differ.
    private static let relevantChanges: CollectionChange = [.deck, .card, .config, .deckConfig, .studyQueues]

    public init(store: CollectionStore) {
        self.store = store
    }

    /// Reads the deck list and today's counts from the core.
    public func refresh() async {
        do {
            let root = try await store.dueDeckTree()
            let currentDeck = try await store.core.getCurrentDeck()
            // The core groups reviews by the scheduling day and excludes
            // manual rescheduling from Today.
            let graphs = try await store.core.graphs(.with { $0.days = 1 })
            decks = root.children.map { DeckNode($0) }
            studiedToday = Int(graphs.today.answerCount)
            currentDeckID = currentDeck.id
            state = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Shows the deck list, then keeps it current whenever the collection
    /// changes in a way that could alter it, until the calling task is
    /// cancelled. The deck list screen runs this in its `.task`.
    public func run() async {
        // Subscribed before reading, so no change in between is missed. A new
        // subscription each time: SwiftUI cancels and restarts the task when
        // the screen disappears and reappears, and cancelling ends a stream.
        let changes = store.changes()
        await refresh()
        for await change in changes where !change.isDisjoint(with: Self.relevantChanges) {
            await refresh()
        }
    }
}
