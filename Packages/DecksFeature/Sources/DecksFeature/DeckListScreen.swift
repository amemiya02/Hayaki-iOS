import CollectionStore
import DeckOptionsFeature
import HayakiAppearance
import PackagesFeature
import StudyFeature
import SwiftUI

/// A deck queued by an external study or options destination.
public struct DeckPresentation: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let deckID: Int64
    public let showsOptions: Bool

    public init(deckID: Int64, showsOptions: Bool) {
        self.deckID = deckID
        self.showsOptions = showsOptions
    }
}

/// The Decks section: every deck as a nested list with today's counts. Tapping
/// a deck starts studying it, full screen.
public struct DeckListScreen<SyncControl: View>: View {
    @State private var model: DeckListModel
    @State private var studying: StudyDeck?
    /// Whether the session was started by Study All, which goes on to the
    /// next deck with cards left when a finished deck is closed.
    @State private var studyingAll = false
    @State private var optionsDeck: DeckNode?
    @Binding private var presentation: DeckPresentation?
    @State private var selectedDeckID: DeckNode.ID?
    @AppStorage(DeckBackground.revisionKey) private var backgroundRevision = ""
    @State private var backgroundImage: CGImage?
    @AppStorage(DeckBackgroundStyle.dimmingKey) private var backgroundDimming = DeckBackgroundStyle.defaultDimming
    @AppStorage(DeckBackgroundStyle.rowOpacityKey) private var rowOpacity = DeckBackgroundStyle.defaultRowOpacity
    @Environment(\.scenePhase) private var scenePhase
    private let store: CollectionStore
    private let profileID: UUID?
    private let syncControl: SyncControl

    public init(
        store: CollectionStore,
        profileID: UUID? = nil,
        presentation: Binding<DeckPresentation?> = .constant(nil),
        @ViewBuilder syncControl: () -> SyncControl
    ) {
        self.store = store
        self.profileID = profileID
        self.syncControl = syncControl()
        _presentation = presentation
        _model = State(initialValue: DeckListModel(store: store))
    }

    public var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { deckBackground }
                .navigationTitle(Text("Decks", bundle: .module))
                .toolbar {
                    // One glass capsule: sync, Add Note and a menu with the rest.
                    ToolbarItemGroup(placement: .primaryAction) {
                        syncControl
                        AddNoteButton()
                        optionsMenu
                    }
                }
                .deckManagement(model, profileID: profileID) { deck in
                    selectedDeckID = deck.id
                    studying = deck
                }
        }
        .packageSheets(store: store)
        // The study session covers the deck list, so the list does not follow
        // each answer meanwhile; it catches up when the session closes.
        .task(id: studying == nil) {
            guard studying == nil else { return }
            await model.run()
        }
        .task(id: backgroundRevision) {
            let image = await DeckBackground(collectionFolder: store.location.folder).image()
            if !Task.isCancelled { backgroundImage = image }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refresh() }
            }
        }
        .onChange(of: selectedDeck?.id, initial: true) { _, id in
            selectedDeckID = id
        }
        .onChange(of: presentation, initial: true) { _, _ in openRequestedDeck() }
        .onChange(of: model.state) { _, _ in openRequestedDeck() }
        .onChange(of: studying) { closed, now in
            if let closed, now == nil {
                Task { await continueStudyAll(after: closed) }
            }
        }
        .sheet(item: $optionsDeck) { deck in
            if deck.isFiltered {
                FilteredDeckScreen(store: store, deckID: deck.id)
            } else {
                DeckOptionsScreen(store: store, deckID: deck.id)
            }
        }
        .studySession(of: $studying, store: store)
    }

    /// The `⋯` menu: importing and exporting, and creating decks.
    private var optionsMenu: some View {
        Menu {
            Section {
                ImportPackageButton()
                ExportPackageButton(store: store)
                SharedDecksLink()
            }
            Section {
                TextImportButton()
                TextExportButton(store: store)
            }
            Section {
                NewDeckButton()
                NewFilteredDeckButton()
            }
        } label: {
            Label {
                Text("Deck List Options", bundle: .module)
            } icon: {
                Image(systemName: "ellipsis")
            }
        }
        .accessibilityIdentifier("deck-list-options")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            DeckListPlaceholder()
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("Could Not Show Decks", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message)
            } actions: {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Text("Try Again", bundle: .module)
                }
            }
        case .loaded where model.hasNoCards && !model.hasOwnDecks:
            ContentUnavailableView {
                Label {
                    Text("No Cards Yet", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.stack")
                }
            } description: {
                Text("Import a deck package (.apkg) or a collection package (.colpkg) from Hayaki, Anki or AnkiDroid.", bundle: .module)
            } actions: {
                VStack {
                    SharedDecksLink()
                        .buttonStyle(.borderedProminent)
                        .hayakiProminentLabel()
                    ImportPackageButton()
                    NewDeckButton()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .loaded:
            let selection = selectedDeck?.id
            List {
                TodayDeckSummary(
                    counts: model.today,
                    studied: model.studiedToday,
                    deck: deckToStudy,
                    canStudyAll: !model.studyAllDecks.isEmpty,
                    onStudyAll: studyAll,
                    onStudy: study
                )
                .deckRowBackground()
                ForEach(model.decks) { deck in
                    DeckRows(deck: deck, selectedDeckID: selection, study: study)
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.deckRowOpacity, backgroundImage == nil ? nil : rowOpacity)
            .refreshable { await model.refresh() }
            .environment(model)
        }
    }

    private var deckBackground: some View {
        GeometryReader { geometry in
            if let backgroundImage {
                Image(decorative: backgroundImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(HayakiBackground(.grouped).opacity(backgroundDimming))
            } else {
                HayakiBackground(.grouped)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var selectedDeck: DeckNode? {
        // Keep the selection when an import brings in a different current
        // deck. Fall back to the core when the chosen deck no longer exists.
        selectedDeckID.flatMap(model.deck) ?? model.currentDeckID.flatMap(model.deck)
    }

    private var deckToStudy: DeckNode? {
        if let selectedDeck, !selectedDeck.counts.isEmpty { return selectedDeck }
        return model.decks.first { !$0.counts.isEmpty }
    }

    private func openRequestedDeck() {
        guard let request = presentation, model.state == .loaded else { return }
        presentation = nil
        guard let deck = model.deck(request.deckID) else { return }
        if request.showsOptions {
            optionsDeck = deck
        } else {
            study(deck)
        }
    }

    private func study(_ deck: DeckNode) {
        studyingAll = false
        selectedDeckID = deck.id
        studying = StudyDeck(id: deck.id, name: deck.name)
    }

    /// Studies the whole collection: each top-level deck with cards left
    /// today in turn, moving on when the learner closes a finished deck.
    private func studyAll() {
        guard let first = model.studyAllDecks.first else { return }
        studyingAll = true
        studying = StudyDeck(id: first.id, name: first.name)
    }

    private func continueStudyAll(after closed: StudyDeck) async {
        guard studyingAll else { return }
        await model.refresh()
        guard studyingAll, let next = model.nextStudyAllDeck(after: closed.id) else {
            studyingAll = false
            return
        }
        // Let the closed session's cover finish dismissing first.
        try? await Task.sleep(for: .milliseconds(500))
        guard studyingAll, studying == nil else { return }
        studying = StudyDeck(id: next.id, name: next.name)
    }
}

/// The Today card: today's new, learning and due cards over all decks, how
/// many answers were recorded today, and buttons to study every deck or the
/// selected one.
private struct TodayDeckSummary: View {
    let counts: DeckCounts
    let studied: Int
    let deck: DeckNode?
    let canStudyAll: Bool
    let onStudyAll: () -> Void
    let onStudy: (DeckNode) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if counts.isEmpty {
                            Text("Nothing due today", bundle: .module)
                        } else {
                            Text("\(counts.total) due today", bundle: .module)
                        }
                    }
                    .font(.headline)
                    .accessibilityIdentifier("due-today")
                    Text("\(studied) studied today", bundle: .module)
                        .font(isCompact ? .footnote : .subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("studied-today")
                }
                totals
                buttons
            }
            .padding(.vertical, isCompact ? 2 : 6)
        }
    }

    /// At accessibility text sizes the card keeps to a few lines, so the
    /// first decks still show below it.
    private var isCompact: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    @ViewBuilder
    private var totals: some View {
        Group {
            if isCompact {
                // Each count with its label, wrapping onto as many lines as needed.
                WrappingRow(spacing: 12, lineSpacing: 2) {
                    inlineTotal(counts.new, color: SemanticColor.new.color, label: Text("New", bundle: .module))
                    inlineTotal(
                        counts.learning, color: SemanticColor.learning.color, label: Text("Learning", bundle: .module)
                    )
                    inlineTotal(counts.due, color: SemanticColor.due.color, label: Text("Due", bundle: .module))
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    total(counts.new, color: SemanticColor.new.color, label: Text("New", bundle: .module))
                    total(counts.learning, color: SemanticColor.learning.color, label: Text("Learning", bundle: .module))
                    total(counts.due, color: SemanticColor.due.color, label: Text("Due", bundle: .module))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            "\(counts.new) new, \(counts.learning) learning, \(counts.due) due",
            bundle: .module
        ))
        .accessibilityIdentifier("today-counts")
    }

    private func total(_ value: Int, color: Color, label: Text) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Digits only in SF Rounded; the label stays in the system font,
            // which has the Chinese and Japanese glyphs.
            Text(value, format: .number)
                .font(.title.weight(.semibold))
                .hayakiNumeric()
                .foregroundStyle(value == 0 ? Color.secondary : color)
            label
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineTotal(_ value: Int, color: Color, label: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value, format: .number)
                .font(.subheadline.weight(.semibold))
                .hayakiNumeric()
                .foregroundStyle(value == 0 ? Color.secondary : color)
            label
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var buttons: some View {
        if canStudyAll {
            Button(action: onStudyAll) {
                Text("Study All", bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .hayakiProminentLabel()
            .controlSize(isCompact ? .regular : .large)
            .accessibilityHint(Text("Studies every deck with cards left today.", bundle: .module))
            .accessibilityIdentifier("study-all")
        }
        // At accessibility sizes Study All is the card's one button; the
        // selected deck's row below starts that deck.
        if let deck, !(isCompact && canStudyAll) {
            Button {
                onStudy(deck)
            } label: {
                Text("Study Now · \(deck.name)", bundle: .module)
                    .lineLimit(isCompact ? 2 : 1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(isCompact ? .regular : .large)
            .accessibilityIdentifier("study-selected-deck")
        }
    }
}

/// Lays its subviews out in a row, starting a new line whenever the next one
/// would not fit, like words in a paragraph.
private struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if !line.indices.isEmpty, added > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

/// The shape of the deck list while the core loads it: today's summary and a
/// few deck rows, as placeholder bars.
private struct DeckListPlaceholder: View {
    // Never shown: redaction draws these as bars of about this width.
    private static let names = ["Japanese Vocabulary", "Kanji", "Grammar", "Spanish", "Geography Capitals"]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "000 due today")
                        .font(.headline)
                    Text(verbatim: "00 studied today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: 200, height: 44)
                        .padding(.top, 6)
                }
                .padding(.vertical, 6)
            }
            ForEach(Self.names, id: \.self) { name in
                HStack {
                    Text(verbatim: name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in
                            Text(verbatim: "00")
                                .frame(minWidth: 24, alignment: .trailing)
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .loadingPlaceholder()
    }
}

/// A deck and, below it, its child decks, which can be collapsed.
private struct DeckRows: View {
    let deck: DeckNode
    let selectedDeckID: DeckNode.ID?
    let study: (DeckNode) -> Void
    @Environment(DeckListModel.self) private var model

    var body: some View {
        if deck.children.isEmpty {
            row
                .deckActions(for: deck)
                .deckRowBackground()
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(deck.children) { child in
                    DeckRows(deck: child, selectedDeckID: selectedDeckID, study: study)
                }
            } label: {
                row
                    .deckActions(for: deck)
            }
            .deckRowBackground()
        }
    }

    private var row: some View {
        DeckRow(deck: deck, isSelected: deck.id == selectedDeckID, study: study)
    }

    /// Whether the child decks show; the core remembers it for next time.
    private var isExpanded: Binding<Bool> {
        Binding {
            !deck.isCollapsed
        } set: { isExpanded in
            Task { try? await model.setCollapsed(!isExpanded, deck: deck.id) }
        }
    }
}

private struct DeckRow: View {
    let deck: DeckNode
    let isSelected: Bool
    let study: (DeckNode) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout())
        Button {
            study(deck)
        } label: {
            layout {
                HStack {
                    Text(verbatim: deck.name)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CountsView(counts: deck.counts)
                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
            }
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("Studies this deck.", bundle: .module))
    }
}

/// Today's new, learning and due counts as rounded pills in Anki's colours:
/// blue, red and green. A count of 0 gets no pill.
private struct CountsView: View {
    let counts: DeckCounts

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { pills }
            VStack(alignment: .trailing, spacing: 4) { pills }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            "\(counts.new) new, \(counts.learning) learning, \(counts.due) due",
            bundle: .module
        ))
    }

    @ViewBuilder
    private var pills: some View {
        if counts.new > 0 { CountPill(value: counts.new, color: SemanticColor.new.color) }
        if counts.learning > 0 { CountPill(value: counts.learning, color: SemanticColor.learning.color) }
        if counts.due > 0 { CountPill(value: counts.due, color: SemanticColor.due.color) }
    }
}

private struct CountPill: View {
    let value: Int
    let color: Color

    var body: some View {
        Text(value, format: .number)
            .font(.subheadline.weight(.semibold))
            .hayakiNumeric()
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(minWidth: 28)
            .background(color.opacity(0.15), in: .capsule)
    }
}


public extension DeckListScreen where SyncControl == EmptyView {
    init(
        store: CollectionStore,
        profileID: UUID? = nil,
        presentation: Binding<DeckPresentation?> = .constant(nil)
    ) {
        self.init(store: store, profileID: profileID, presentation: presentation) { EmptyView() }
    }
}

extension EnvironmentValues {
    /// How solid deck rows are over the learner's background image, or nil
    /// with no image.
    @Entry var deckRowOpacity: Double?
}

/// Rows the background image shows through, when one is chosen.
private struct DeckRowBackground: ViewModifier {
    @Environment(\.deckRowOpacity) private var opacity

    func body(content: Content) -> some View {
        if let opacity {
            content.listRowBackground(DeckRowSurface(opacity: opacity))
        } else {
            content
        }
    }
}

extension View {
    fileprivate func deckRowBackground() -> some View {
        modifier(DeckRowBackground())
    }
}
