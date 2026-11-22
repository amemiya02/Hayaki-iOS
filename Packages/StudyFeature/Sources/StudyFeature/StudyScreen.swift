import AnkiCore
import CollectionStore
import HayakiAppearance
import SwiftUI

/// A deck the learner chose to study.
public struct StudyDeck: Identifiable, Hashable, Sendable {
    public let id: Int64
    /// The deck's own name, shown at the top of the study screen.
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

extension View {
    /// Supplies the sheet the reviewer opens when the learner edits a note.
    public func studyNoteEditor<Editor: View>(
        @ViewBuilder _ editor: @escaping @MainActor @Sendable (Int64) -> Editor
    ) -> some View {
        environment(\.studyNoteEditor, StudyNoteEditor { cardID in AnyView(editor(cardID)) })
    }

    /// Presents a full-screen study session over `deck` while it is set,
    /// and sets it back to nil when the learner closes the session.
    public func studySession(of deck: Binding<StudyDeck?>, store: CollectionStore) -> some View {
        #if os(iOS)
        fullScreenCover(item: deck) { deck in
            StudyScreen(store: store, deck: deck)
        }
        #else
        sheet(item: deck) { deck in
            StudyScreen(store: store, deck: deck)
        }
        #endif
    }
}

/// The study screen: the card fills the screen under a navigation bar with the
/// deck and its counts, and Show Answer or the four rating buttons sit at the
/// bottom, within thumb reach.
public struct StudyScreen: View {
    @State private var model: StudySessionModel
    /// What the learner typed on a card that asks for typing.
    @State private var typedAnswer = ""
    @State private var editedCard: EditedCard?
    @State private var editedNoteTags: EditedNoteTags?
    @State private var preferences = ReviewerPreferences.load()
    @State private var webCommand: ReviewerWebCommand?
    @State private var pendingTap: Task<Void, Never>?
    /// Whether a text field on the card has focus; keys that type text then
    /// go to the field instead of the Study menu's shortcuts.
    @State private var editingCardText = false
    @FocusState private var reviewerFocused: Bool
    @State private var showingSettings = false
    @State private var requestedAction: ReviewerCommand?
    @State private var route: ReviewerDestination?
    @State private var nextStudy: StudyDeck?
    /// The card page's own background, once it reports one.
    @State private var cardCanvas: CardCanvasColor?
    #if os(iOS)
    @State private var cardHostUnavailable = false
    @State private var cardHostRevision = 0
    #endif
    /// The height of the answer bar (and recorder) floating over the card.
    @State private var bottomControlsHeight: CGFloat = 0
    @State private var autoAdvance = false
    @State private var timebox: StudyTimebox?
    @State private var feedback: ReviewFeedback?
    @State private var templateFullscreen: TemplateFullscreen = .standard
    @State private var templateMenu: TemplateMenu?
    @Environment(\.reviewerDestination) private var destinations
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.studyNoteEditor) private var noteEditor
    #if os(iOS)
    @State private var audio = CardAudioPlayer()
    @State private var templateSpeech = TemplateSpeech()
    @State private var templateRecognition = TemplateRecognition()
    @State private var templateNetwork = TemplateNetworkStatus()
    @AppStorage(CardTemplatePreference.microphone) private var allowsTemplateMicrophone = false
    @AppStorage(CardTemplatePreference.collectionAccess) private var allowsTemplateCollectionAccess = false
    @State private var recorder = AudioRecorder()
    @State private var drawing = ReviewerDrawing()
    @State private var isErasing = false
    @State private var deckTools: ReviewerDeckTools
    #endif
    private let store: CollectionStore
    @State private var deckName: String
    private let profileFolder: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hayakiTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(store: CollectionStore, deck: StudyDeck) {
        self.store = store
        _model = State(initialValue: StudySessionModel(store: store, deckID: deck.id))
        _deckName = State(initialValue: deck.name)
        profileFolder = store.location.folder
        #if os(iOS)
        _deckTools = State(initialValue: ReviewerDeckTools.load(profile: store.location.folder, deckID: deck.id))
        #endif
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                // A card's template can hide the navigation bar but keep the
                // reviewer's actions, which then sit below the card.
                if templateFullscreen.showsActions, !showsNavigationBar {
                    reviewerActions
                }
            }
            .overlay(alignment: .top) { progressLine }
            .hayakiBackground(.plain)
            .navigationTitle(title)
            .toolbar { navigationBarItems }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showsNavigationBar ? .automatic : .hidden, for: .navigationBar)
            #endif
        }
        .task(id: ObjectIdentifier(model)) { await model.run() }
        .task(id: autoAdvanceTask) { await runAutoAdvance() }
        .task(id: feedback) {
            guard feedback != nil else { return }
            let duration = feedback?.duration ?? .seconds(2)
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { feedback = nil }
        }
        .onChange(of: model.reviewedCount) {
            if model.state.card != nil, let progress = model.timeboxProgress() { timebox = progress }
        }
        .overlay(alignment: .top) {
            ZStack {
                if let feedback {
                    ReviewFeedbackToast(feedback: feedback)
                        .id(feedback.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.85, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
                        ))
                }
            }
            .padding(.top, 56)
            .padding(.horizontal, 24)
            .allowsHitTesting(false)
            .animation(.spring(response: 0.36, dampingFraction: 0.78), value: feedback)
        }
        .modifier(TemplateMenuPresentation(selection: $templateMenu, dispatch: dispatch, onSettings: { showingSettings = true }))
        .overlay(alignment: .topLeading) {
            if !templateFullscreen.showsTopBar, model.state.card != nil {
                Button {
                    templateFullscreen = .standard
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(Text("Leave Full Screen", bundle: .module))
                .padding(8)
            }
        }
        .modifier(ReviewerActionDialogs(model: model, requestedAction: $requestedAction))
        .sheet(item: $route, onDismiss: returnFromDestination) { route in
            destinations?.make(route) { nextStudy = $0 }
        }
        .alert(reviewerLocalized("Timebox Reached"), isPresented: Binding(
            get: { timebox != nil },
            set: { if !$0 { timebox = nil } }
        )) {
            Button(reviewerLocalized("Continue")) {
                model.restartTimebox()
                timebox = nil
            }
            Button(reviewerLocalized("Finish")) { dismiss() }
        } message: {
            if let timebox {
                Text("You reviewed \(timebox.reviewed) cards in \(timebox.limit.components.seconds / 60) minutes.", bundle: .module)
            }
        }
        .focusable()
        .focused($reviewerFocused)
        .onAppear { reviewerFocused = true }
        .onKeyPress { press in
            guard press.phase == .down else { return .ignored }
            return dispatchInput(.keyboard(ReviewerKey(press))) ? .handled : .ignored
        }
        .focusedSceneValue(\.reviewerShortcutMenu, side.map { side in
            ReviewerShortcutMenu(
                shortcuts: preferences.keyboardShortcuts(on: side), isEnabled: acceptsInput,
                isEditingText: editingCardText
            ) { _ = dispatchInput(.keyboard($0)) }
        })
        .focusedSceneValue(\.focusedAddNote, acceptsInput ? AddNoteAction { dispatch(.addNote) } : nil)
        #if os(iOS)
        .task(id: model.customSchedulingRequest?.id) {
            guard let work = model.customSchedulingRequest else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { await model.applyCustomSchedule(requestID: work.id, json: nil) }
        }
        .statusBarHidden(preferences.hideStatusBar || !templateFullscreen.showsTopBar)
        .persistentSystemOverlays(preferences.hideHomeIndicator ? .hidden : .automatic)
        .modifier(ReviewerIdleTimer(enabled: preferences.keepScreenOn || autoAdvance))
        .modifier(ReviewerController { _ = dispatchInput($0) })
        .modifier(ReviewerShake(
            enabled: side.flatMap { preferences.command(for: .gesture(.shake), on: $0) } != nil
        ) { _ = dispatchInput(.gesture(.shake)) })
        .onChange(of: deckTools) { _, value in
            value.save(profile: profileFolder, deckID: model.deckID)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { templateRecognition.stop() }
        }
        .onDisappear {
            recorder.discard()
            audio.stop()
        }
        .alert(reviewerLocalized("Recording"), isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.clearError() } }
        )) {
            if recorder.permissionDenied {
                Button(reviewerLocalized("Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button(reviewerLocalized("OK"), role: .cancel) { recorder.clearError() }
        } message: {
            Text(verbatim: recorder.errorMessage ?? "")
        }
        #endif
        .onDisappear {
            pendingTap?.cancel()
            pendingTap = nil
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            preferences = ReviewerPreferences.load()
            Task { await model.refreshReviewerPreferences() }
        }) {
            NavigationStack {
                ReviewerSettingsScreen(store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(reviewerLocalized("Done")) { showingSettings = false }
                        }
                    }
            }
        }
        .sheet(item: $editedNoteTags) { note in
            ReviewerTagsSheet(model: model, noteID: note.id)
        }
        .sheet(item: $editedCard) { card in
            noteEditor?.make(card.id)
        }
        .alert(
            Text("Study Action Failed", bundle: .module),
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.clearActionError() } }
            )
        ) {
            Button { model.clearActionError() } label: { Text("OK", bundle: .module) }
        } message: {
            Text(verbatim: model.actionError ?? "")
        }
    }

    private func returnFromDestination() {
        let requested = nextStudy
        nextStudy = nil
        guard let requested, requested.id != model.deckID else {
            Task { await model.refreshAfterExternalChanges() }
            return
        }
        deckName = requested.name
        typedAnswer = ""
        autoAdvance = false
        templateFullscreen = .standard
        templateMenu = nil
        timebox = nil
        #if os(iOS)
        recorder.discard()
        deckTools = ReviewerDeckTools.load(profile: profileFolder, deckID: requested.id)
        drawing.clear()
        #endif
        model = StudySessionModel(store: store, deckID: requested.id)
    }

    private var side: ReviewerSide? {
        if model.state.answer != nil { return .answer }
        return model.state.question == nil ? nil : .question
    }

    private var keySignatures: [String] {
        preferences.bindings.compactMap { binding in
            guard binding.side == side, case .keyboard(let key) = binding.input else { return nil }
            return ([key.name] + key.modifiers.map(\.rawValue).sorted()).joined(separator: "+")
        }
    }

    /// Whether a key, gesture or controller input reaches the reviewer now.
    private var acceptsInput: Bool {
        editedCard == nil && editedNoteTags == nil && !showingSettings && requestedAction == nil
            && route == nil && timebox == nil && !model.isBusy
    }

    private func dispatchInput(_ input: ReviewerInput) -> Bool {
        guard acceptsInput, let side, let command = preferences.command(for: input, on: side) else { return false }
        dispatch(command)
        return true
    }

    func dispatch(_ command: ReviewerCommand) {
        guard !model.isBusy else { return }
        switch command {
        case .exit: dismiss()
        case .edit:
            if let id = model.state.card?.id, noteEditor != nil { editedCard = EditedCard(id: id) }
        case .editTags:
            if let noteID = model.state.card?.noteID { editedNoteTags = EditedNoteTags(id: noteID) }
        case .deleteNote, .setDueDate, .resetProgress: requestedAction = command
        case .toggleAutoAdvance:
            autoAdvance.toggle()
            feedback = ReviewFeedback(label: autoAdvance
                ? Text("Auto Advance Enabled", bundle: .module)
                : Text("Auto Advance Disabled", bundle: .module))
        case .browse:
            guard destinations != nil else { return }
            Task {
                route = try? await model.browseDestination()
            }
        case .statistics: route = .statistics(deckID: model.deckID)
        case .deckOptions: route = .deckOptions(deckID: model.state.card?.homeDeckID ?? model.deckID)
        case .cardInfo:
            if let id = model.state.card?.id { route = .cardInfo(cardID: id) }
        case .previousCardInfo:
            if let id = model.previousCardID { route = .cardInfo(cardID: id) }
        case .addNote: route = .addNote(homeDeckID: model.state.card?.homeDeckID)
        case .showHint:
            webCommand = ReviewerWebCommand(javascript: """
            if (window.ankidroid?.showHint) {
                window.ankidroid.showHint();
            } else {
                document.querySelector('a.hint:not([style*=none])')?.click();
            }
            """)
        case .showAllHints:
            webCommand = ReviewerWebCommand(javascript: """
            if (window.ankidroid?.showAllHints) {
                window.ankidroid.showAllHints();
            } else {
                document.querySelectorAll('a.hint:not([style*=none])').forEach(a => a.click());
            }
            """)
        case .pageUp:
            webCommand = ReviewerWebCommand(javascript: "window.scrollBy({top: -window.innerHeight})")
        case .pageDown:
            webCommand = ReviewerWebCommand(javascript: "window.scrollBy({top: window.innerHeight})")
        case .replayMedia:
            #if os(iOS)
            if recorder.state == .recording || recorder.state == .paused { recorder.stopRecording() }
            recorder.stopPlayback()
            audio.play(model.soundsToReplay())
            #endif
        case .toggleWhiteboard:
            #if os(iOS)
            deckTools.whiteboardEnabled.toggle()
            #endif
        case .recordVoice:
            #if os(iOS)
            deckTools.recorderShown.toggle()
            if !deckTools.recorderShown { recorder.discard() }
            #endif
        case .replayVoice:
            #if os(iOS)
            if recorder.file != nil {
                deckTools.recorderShown = true
                audio.stopAndReleaseSession()
                recorder.play()
            }
            #endif
        default:
            if let number = command.userActionNumber {
                webCommand = ReviewerWebCommand(javascript: "window.ankidroid?.userAction?.(\(number))")
            } else {
                let typed = typedAnswer
                let interval = model.showsRatingIntervals
                    ? command.rating.flatMap { model.state.card?.intervals[$0] } : nil
                Task {
                    guard await model.perform(command, typed: typed), let rating = command.rating else { return }
                    switch model.leechFeedback {
                    case .tagged:
                        feedback = ReviewFeedback(label: Text("Card was a leech.", bundle: .module))
                    case .suspended:
                        feedback = ReviewFeedback(label: Text("Card was a leech and has been suspended.", bundle: .module))
                    case nil:
                        if preferences.showFeedback {
                            feedback = ReviewFeedback(label: rating.title, rating: rating, interval: interval)
                        }
                    }
                }
            }
        }
    }

    private func handleWebInput(_ input: ReviewerWebInput) {
        guard let side, let cardID = model.state.card?.id else { return }
        switch input {
        case .input(let input): _ = dispatchInput(input)
        case .editing(let editing): editingCardText = editing
        case .swipe(let dx, let dy, let time):
            let scale = 100 / Double(max(preferences.swipeSensitivity, 1))
            guard hypot(dx, dy) >= 44 * scale, hypot(dx, dy) / max(1, time) >= 0.2 * scale else { return }
            let gesture: ReviewerGesture = abs(dx) > abs(dy)
                ? (dx < 0 ? .swipeLeft : .swipeRight)
                : (dy < 0 ? .swipeUp : .swipeDown)
            _ = dispatchInput(.gesture(gesture))
        case .tap(let x, let y):
            let zone = preferences.tapZones.gesture(x: x, y: y)
            if preferences.doubleTapMilliseconds > 0, preferences.command(for: .gesture(.doubleTap), on: side) != nil {
                if let pendingTap {
                    pendingTap.cancel()
                    self.pendingTap = nil
                    _ = dispatchInput(.gesture(.doubleTap))
                } else {
                    pendingTap = Task {
                        try? await Task.sleep(for: .milliseconds(preferences.doubleTapMilliseconds))
                        guard !Task.isCancelled else { return }
                        pendingTap = nil
                        guard self.side == side, model.state.card?.id == cardID else { return }
                        _ = dispatchInput(.gesture(zone))
                    }
                }
            } else {
                _ = dispatchInput(.gesture(zone))
            }
        }
    }

    private var autoAdvanceTask: AutoAdvanceTask? {
        guard autoAdvance, let side, let plan = model.autoAdvancePlan,
              scenePhase == .active, !showingSettings, editedCard == nil, editedNoteTags == nil,
              requestedAction == nil, route == nil, timebox == nil else { return nil }
        #if os(iOS)
        guard recorder.state != .recording, recorder.state != .paused else { return nil }
        #endif
        return AutoAdvanceTask(presentation: model.presentationNumber, side: side, plan: plan)
    }

    private func runAutoAdvance() async {
        guard let task = autoAdvanceTask else { return }
        #if os(iOS)
        if task.plan.waitForAudio {
            await Task.yield()
            await audio.waitForCompletion()
        }
        #endif
        do {
            try await Task.sleep(for: task.plan.delay)
        } catch { return }
        guard autoAdvanceTask == task else { return }
        if let command = task.plan.command {
            dispatch(command)
        } else {
            feedback = ReviewFeedback(label: task.side == .question
                ? Text("Question Time Elapsed", bundle: .module)
                : Text("Answer Time Elapsed", bundle: .module))
        }
    }

    private var showsNavigationBar: Bool {
        templateFullscreen.showsTopBar || model.state.card == nil
    }

    private var title: String {
        preferences.showDeckTitle && !model.currentDeckName.isEmpty ? model.currentDeckName : deckName
    }

    /// The system navigation bar: Close, the deck with the counts below it,
    /// and the reviewer's actions.
    @ToolbarContentBuilder
    private var navigationBarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Label {
                    Text("Close", bundle: .module)
                } icon: {
                    Image(systemName: "xmark")
                }
            }
            .keyboardShortcut(.cancelAction)
        }
        #if os(iOS)
        if showsNavigationDetail {
            ToolbarItem(placement: .subtitle) { navigationDetail }
        }
        #else
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if showsNavigationDetail { navigationDetail }
            }
        }
        #endif
        if model.state.card != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                reviewerToolbar.barButtons
            }
            ToolbarItem(placement: .primaryAction) {
                reviewerToolbar.menu
            }
        } else {
            // With no card to act on, only the settings remain.
            ToolbarItem(placement: .primaryAction) {
                Button(reviewerLocalized("Reviewer Settings"), systemImage: "gear") { showingSettings = true }
            }
        }
    }

    private var showsNavigationDetail: Bool {
        model.state.card != nil && (model.showsRemainingCounts || model.showsAnswerTimer)
    }

    private var navigationDetail: some View {
        HStack(spacing: 8) {
            if model.showsRemainingCounts {
                StudyCountsView(counts: model.counts)
            }
            if model.showsAnswerTimer {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(model.answerTimer().formatted(.time(pattern: .minuteSecond)))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(reviewerLocalized("Answer Timer"))
                }
            }
        }
        .hayakiNumeric()
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A thin line along the bottom edge of the navigation bar.
    @ViewBuilder
    private var progressLine: some View {
        if showsNavigationBar, preferences.showProgress, model.showsRemainingCounts, model.hasStudyProgress {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .labelsHidden()
                .scaleEffect(x: 1, y: 0.5, anchor: .top)
                .accessibilityLabel(reviewerLocalized("Study Progress"))
        }
    }

    @ViewBuilder
    private var content: some View {
        // One view for both sides of every card, so the card's web view and
        // its page stay loaded for the whole session.
        if let card = model.state.card {
            studying(card, showingAnswer: model.state.answer != nil)
        } else {
            noCard
        }
    }

    @ViewBuilder
    private var noCard: some View {
        switch model.state {
        case .loading, .question, .answer:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .finished(let summary):
            FinishedView(
                summary: summary,
                onUnbury: { Task { await model.unburyDeck() } },
                onRebuild: { Task { await model.rebuildFinishedFilteredDeck() } },
                onOptions: destinations == nil || summary.isFiltered ? nil : { route = .deckOptions(deckID: model.deckID) },
                onCustomStudy: destinations == nil || summary.isFiltered ? nil : { route = .customStudy(deckID: model.deckID) },
                onDone: { dismiss() }
            )
        case .failed(let message):
            ContentUnavailableView {
                Label {
                    Text("Could Not Continue Studying", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message)
            } actions: {
                Button {
                    dismiss()
                } label: {
                    Text("Close", bundle: .module)
                }
            }
        }
    }

    /// The widest the card grows in a regular-width window (iPad full screen
    /// and the larger split-view sizes); narrower windows use their full width.
    static let readableCardWidth: CGFloat = 820

    /// Whether the answer bar or the recorder floats over the bottom of the card.
    private var showsBottomControls: Bool {
        #if os(iOS)
        if deckTools.recorderShown { return true }
        #endif
        return preferences.showAnswerButtons && templateFullscreen.showsAnswer
    }

    /// How far the card's content must be able to scroll above the bottom controls.
    private var cardBottomInset: CGFloat {
        showsBottomControls ? bottomControlsHeight : 0
    }

    private func studying(_ card: StudyCard, showingAnswer: Bool) -> some View {
        cardView(CardDisplay(card, isAnswer: showingAnswer, presentation: model.presentationNumber))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(preferences.cardFrame ? 8 : 0)
            .background(preferences.cardFrame ? theme.surface : Color.clear)
            .clipShape(.rect(cornerRadius: preferences.cardFrame ? 18 : 0))
            .overlay {
                if preferences.cardFrame {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(.secondary.opacity(0.2))
                        .allowsHitTesting(false)
                }
            }
            #if os(iOS)
            .overlay {
                if deckTools.whiteboardEnabled && deckTools.drawingShown {
                    ReviewerWhiteboard(drawing: drawing, tools: deckTools, isErasing: isErasing)
                }
            }
            .overlay(alignment: whiteboardAlignment) {
                if deckTools.whiteboardEnabled {
                    ReviewerWhiteboardTools(drawing: drawing, options: $deckTools, isErasing: $isErasing)
                        .padding(8)
                        .padding(.bottom, whiteboardAlignment == .bottom ? cardBottomInset : 0)
                }
            }
            #endif
            // On an iPad, the whole card is a centered readable column.
            .frame(maxWidth: horizontalSizeClass == .regular ? Self.readableCardWidth : .infinity)
            .frame(maxWidth: .infinity)
            // The card's own background fills the screen around that column
            // and below the answer bar, so there is no seam where the page ends.
            .background {
                if let cardCanvas, !preferences.cardFrame {
                    cardCanvas.color.ignoresSafeArea(edges: [.horizontal, .bottom])
                }
            }
            // The answer bar floats over the card in its glass container;
            // the card's content scrolls beneath it.
            .overlay(alignment: .bottom) {
                bottomControls(card, showingAnswer: showingAnswer)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomControlsHeight = $0 }
            }
    }

    @ViewBuilder
    private func bottomControls(_ card: StudyCard, showingAnswer: Bool) -> some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if deckTools.recorderShown {
                HStack {
                    Spacer()
                    ReviewerVoiceControls(recorder: recorder, stopCardAudio: audio.stopAndReleaseSession)
                    Spacer()
                    Button(reviewerLocalized("Hide Recorder"), systemImage: "xmark.circle") {
                        recorder.discard()
                        deckTools.recorderShown = false
                    }
                    .labelStyle(.iconOnly)
                    .padding(.trailing, 12)
                }
                .padding(.vertical, 6)
                // Floating over the card, so it needs its own backing.
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: 640)
                .padding(.horizontal, 16)
            }
            #endif
            if preferences.showAnswerButtons, templateFullscreen.showsAnswer {
                AnswerBar(
                    card: card, showingAnswer: showingAnswer, isAnswering: model.isBusy,
                    minimumPress: Double(preferences.minimumPressMilliseconds) / 1000,
                    cooldown: .milliseconds(preferences.doubleTapMilliseconds),
                    buttonHeight: Double(preferences.answerButtonSize) * 0.52,
                    hideHardAndEasy: preferences.hideHardAndEasy, showsIntervals: model.showsRatingIntervals
                ) {
                    dispatch(.showAnswer)
                } onShortPress: {
                    feedback = ReviewFeedback(label: Text("Hold Show Answer to reveal the card.", bundle: .module))
                } onRate: { rating in
                    dispatch(rating.reviewerCommand)
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
        }
    }

    #if os(iOS)
    private var whiteboardAlignment: Alignment {
        switch deckTools.toolbarAlignment ?? .bottom {
        case .left: .leading
        case .right: .trailing
        case .bottom: .bottom
        }
    }
    #endif

    @ViewBuilder
    private func cardView(_ display: CardDisplay) -> some View {
        #if os(iOS)
        CardWebView(
            display: display, mediaFolder: model.mediaFolder,
            zoom: dynamicTypeSize.cardZoom * Double(preferences.cardZoom) / 100,
            bottomInset: cardBottomInset,
            reviewer: ReviewerWebOptions(
                keySignatures: keySignatures, imageZoom: Double(preferences.imageZoom) / 100,
                centerVertically: preferences.centerVertically, hidesAudioButtons: model.hidesAudioButtons,
                reducedMotion: preferences.reducedMotion, command: webCommand
            ),
            onTemplateRequest: handleTemplateRequest,
            customScheduling: model.customSchedulingRequest,
            onCustomSchedule: { id, json in
                Task { await model.applyCustomSchedule(requestID: id, json: json) }
            }
        ) { event in
            switch event {
            case .tap: break
            case .background(let canvas): cardCanvas = canvas
            case .rendered: cardHostUnavailable = false
            case .unavailable: cardHostUnavailable = true
            case .submitTypedAnswer: dispatch(.showAnswer)
            case .reviewer(let input): handleWebInput(input)
            case .play(let id):
                if recorder.state == .recording || recorder.state == .paused { recorder.stopRecording() }
                recorder.stopPlayback()
                if let sound = model.sound(forPlayButton: id) { audio.play([sound]) }
            case .typed(let text): typedAnswer = text
            }
        }
        .id(cardHostRevision)
        .overlay {
            if cardHostUnavailable {
                CardHostFailure {
                    cardHostUnavailable = false
                    cardHostRevision += 1
                }
            }
        }
        // VoiceOver reads the card's own content inside the web view.
        .accessibilityIdentifier("card")
        // Each side's audio plays when it appears.
        .onChange(of: SideShown(display, presentation: model.presentationNumber), initial: true) {
            if !display.isAnswer { drawing.clear() }
            if recorder.state == .recording || recorder.state == .paused { recorder.stopRecording() }
            recorder.stopPlayback()
            pendingTap?.cancel()
            pendingTap = nil
            // A field removed with the old side never reports losing focus.
            editingCardText = false
            typedAnswer = display.isAnswer ? typedAnswer : ""
            templateRecognition.stop()
            audio.play(
                model.soundsToAutoplay(),
                afterCurrent: display.isAnswer && !model.interruptsAudioWhenAnswering
            )
        }
        .onDisappear {
            audio.stop()
            templateSpeech.stop()
            templateRecognition.stop()
        }
        #else
        Text(verbatim: display.html)
        #endif
    }

    #if os(iOS)
    private func handleTemplateRequest(_ request: TemplateRequest, context: CardTemplateContext) async -> TemplateReply {
        guard context.isCurrent(), store.allowsNewProfileWork, timebox == nil,
              model.state.card?.id == context.cardID else { return .unavailable }
        switch request.command {
        case "isInNightMode": return .value(.boolean(theme.appearance != .light))
        case "isInFullscreen": return .value(.boolean(!templateFullscreen.showsTopBar))
        case "isTopbarShown": return .value(.boolean(templateFullscreen.showsTopBar))
        case "setFullscreenButtonsAndMenu": templateFullscreen = .buttonsAndMenu
        case "setFullscreenButtonsOnly": templateFullscreen = .buttonsOnly
        case "setFullscreenAllGone": templateFullscreen = .hidden
        case "showNavigationDrawer": templateMenu = .navigation
        case "showOptionsMenu": templateMenu = .options
        case "addTagToCard": dispatch(.editTags)
        case "searchCard":
            guard destinations != nil, let query = request.data else { return .unavailable }
            route = .browse(search: query)
        case "showToast":
            guard let toast = request.decoded(TemplateToast.self) else { return .unavailable }
            feedback = ReviewFeedback(
                label: Text(verbatim: toast.decodedText),
                duration: .seconds(toast.shortLength ? 2 : 4)
            )
        case "isActiveNetworkMetered":
            return .value(.boolean(await templateNetwork.isMetered()))
        default:
            if let response = templateSpeech.handle(request, prepareAudio: {
                audio.stopAndReleaseSession()
                templateRecognition.stop()
                if recorder.state == .recording || recorder.state == .paused { recorder.stopRecording() }
                recorder.stopPlayback()
            }) {
                return response
            }
            if let response = await templateRecognition.handle(
                request, context: context, allowed: allowsTemplateMicrophone,
                prepareAudio: {
                    audio.stopAndReleaseSession()
                    templateSpeech.stop()
                    if recorder.state == .recording || recorder.state == .paused { recorder.stopRecording() }
                    recorder.stopPlayback()
                }
            ) {
                return response
            }
            return await model.handleTemplate(
                request, cardID: context.cardID, isAnswer: context.isAnswer, typedAnswer: typedAnswer,
                allowsCollectionAccess: allowsTemplateCollectionAccess
            )
        }
        return .accepted
    }
    #endif

    private var reviewerToolbar: ReviewerToolbar {
        ReviewerToolbar(
            model: model, preferences: preferences, showsEditNote: noteEditor != nil,
            onSettings: { showingSettings = true }, dispatch: dispatch
        )
    }

    private var reviewerActions: some View {
        reviewerToolbar
            .padding(.horizontal, 8)
    }
}

private struct EditedNoteTags: Identifiable {
    let id: Int64
}

private struct EditedCard: Identifiable {
    let id: Int64
}

/// The note editor the reviewer opens. Equal to itself only, so passing the
/// environment down again (as every trait change does) does not count as a
/// change and re-render the study screen; a closure never compares equal.
private struct StudyNoteEditor: Equatable {
    let id = UUID()
    let make: @MainActor @Sendable (Int64) -> AnyView

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

private struct StudyNoteEditorKey: EnvironmentKey {
    static let defaultValue: StudyNoteEditor? = nil
}

private extension EnvironmentValues {
    var studyNoteEditor: StudyNoteEditor? {
        get { self[StudyNoteEditorKey.self] }
        set { self[StudyNoteEditorKey.self] = newValue }
    }
}

/// Which side of which card is shown, to play its audio once when it appears.
private struct SideShown: Equatable {
    let cardID: Int64
    let isAnswer: Bool
    let presentation: Int

    init(_ display: CardDisplay, presentation: Int) {
        cardID = display.cardID
        isAnswer = display.isAnswer
        self.presentation = presentation
    }
}

/// The new, learning and due counts left today, as `12 · 3 · 40` in Anki's
/// blue, red and green.
private struct StudyCountsView: View {
    let counts: StudyCounts

    var body: some View {
        let new = Text(counts.new, format: .number).foregroundStyle(SemanticColor.new.color)
        let learning = Text(counts.learning, format: .number).foregroundStyle(SemanticColor.learning.color)
        let due = Text(counts.due, format: .number).foregroundStyle(SemanticColor.due.color)
        let separator = Text(verbatim: "·").foregroundStyle(.tertiary)

        // Give the counts room before the optional timer uses spare width.
        Text("\(new) \(separator) \(learning) \(separator) \(due)")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .layoutPriority(1)
            .accessibilityLabel(Text(
                "\(counts.new) new, \(counts.learning) learning, \(counts.due) due left",
                bundle: .module
            ))
            .accessibilityIdentifier("study-counts")
    }
}


extension Rating {
    var title: Text {
        switch self {
        case .again: Text("Again", bundle: .module, comment: "Rating: the learner did not recall the card.")
        case .hard: Text("Hard", bundle: .module, comment: "Rating: recalled with serious difficulty.")
        case .good: Text("Good", bundle: .module, comment: "Rating: recalled after some thought.")
        case .easy: Text("Easy", bundle: .module, comment: "Rating: recalled at once.")
        }
    }

    /// Anki's colours for the ratings.
    var semanticColor: SemanticColor {
        switch self {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        }
    }

    /// As in Anki, 1 to 4 rate from the keyboard.
    var key: KeyEquivalent {
        switch self {
        case .again: "1"
        case .hard: "2"
        case .good: "3"
        case .easy: "4"
        }
    }
}

extension DynamicTypeSize {
    /// How much larger or smaller than at the default text size the card is
    /// drawn, so cards follow the learner's text size like the rest of the app.
    var cardZoom: CGFloat {
        switch self {
        case .xSmall: 0.82
        case .small: 0.88
        case .medium: 0.94
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.24
        case .xxxLarge: 1.36
        case .accessibility1: 1.6
        case .accessibility2: 1.9
        case .accessibility3: 2.2
        case .accessibility4: 2.6
        case .accessibility5: 3
        @unknown default: 1
        }
    }
}


private struct AutoAdvanceTask: Equatable {
    let presentation: Int
    let side: ReviewerSide
    let plan: AutoAdvancePlan
}

private struct ReviewFeedback: Equatable {
    let id = UUID()
    let label: Text
    /// The rating just given, when the notice confirms an answer.
    var rating: Rating?
    /// The interval that rating scheduled, when intervals show.
    var interval: String?
    var duration: Duration = .seconds(2)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

/// A short notice under the navigation bar: the rating just given, in its
/// colour with the interval it scheduled, or a plain reviewer notice.
private struct ReviewFeedbackToast: View {
    let feedback: ReviewFeedback
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.rating?.symbol ?? "info.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(feedback.rating == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                .frame(width: 30, height: 30)
                .background {
                    if feedback.rating != nil {
                        Circle().fill(tint.gradient)
                    }
                }
                .symbolEffect(.bounce, value: feedback.id)
            VStack(alignment: .leading, spacing: 0) {
                feedback.label
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let interval = feedback.interval {
                    Text("Next review in \(interval)", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .hayakiNumeric()
                }
            }
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }
        .padding(.leading, feedback.rating == nil ? 12 : 6)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 42)
        .background { surface }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var tint: Color { feedback.rating?.semanticColor.color ?? .secondary }

    @ViewBuilder
    private var surface: some View {
        if reduceTransparency {
            Capsule().fill(.background.secondary)
                .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        } else {
            Capsule().fill(.clear)
                .glassEffect(.regular.tint(feedback.rating == nil ? nil : tint.opacity(0.18)), in: .capsule)
        }
    }
}

private extension Rating {
    /// The mark the answer notice shows for this rating.
    var symbol: String {
        switch self {
        case .again: "arrow.counterclockwise"
        case .hard: "tortoise.fill"
        case .good: "checkmark"
        case .easy: "hare.fill"
        }
    }

    var reviewerCommand: ReviewerCommand {
        switch self {
        case .again: .rateAgain
        case .hard: .rateHard
        case .good: .rateGood
        case .easy: .rateEasy
        }
    }
}

#if os(iOS)
private struct ReviewerIdleTimer: ViewModifier {
    let enabled: Bool
    @State private var previous: Bool?

    func body(content: Content) -> some View {
        content
            .onChange(of: enabled, initial: true) { _, enabled in
                if previous == nil { previous = UIApplication.shared.isIdleTimerDisabled }
                UIApplication.shared.isIdleTimerDisabled = enabled || (previous ?? false)
            }
            .onDisappear {
                if let previous { UIApplication.shared.isIdleTimerDisabled = previous }
                previous = nil
            }
    }
}
#endif
