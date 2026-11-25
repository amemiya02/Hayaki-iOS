import AnkiProto
import CollectionStore
import SwiftUI

/// The RWKV scheduling switch, its status and the model choice (ADR 0007).
struct RwkvSchedulingSection: View {
    let store: CollectionStore
    @State private var status: Anki_ZzHayaki_RwkvStatusResponse?
    @State private var isSaving = false
    @State private var failure: Failure?

    private struct Failure {
        let title: LocalizedStringKey
        let message: String
    }

    var body: some View {
        Group {
            Section {
                if let status {
                    Toggle(isOn: Binding(
                        get: { status.enabled },
                        set: { setEnabled($0) }
                    )) {
                        Text("Schedule Reviews with RWKV", bundle: .module)
                    }
                    .disabled(isSaving)
                    statusRow(status)
                } else {
                    ProgressView()
                }
            } header: {
                Text("RWKV Scheduling", bundle: .module)
            } footer: {
                Text("An RWKV model reads your review history and predicts how likely you are to recall each review card right now. A card comes due when that chance falls to its deck's desired retention, and the cards you are most likely to have forgotten come first. New and learning cards are scheduled as usual. Anki's stored due dates are never changed, so turning this off brings back your usual schedule at once.", bundle: .module)
            }
            if let status {
                Section {
                    Picker(selection: Binding(
                        get: { status.model },
                        set: { setModel($0) }
                    )) {
                        ForEach([Anki_ZzHayaki_RwkvModel.big, .small, .tiny], id: \.self) { model in
                            optionLabel(model).tag(model)
                        }
                    } label: {
                        Text("Model", bundle: .module)
                    }
                    .pickerStyle(.inline)
                    // The section header already names it.
                    .labelsHidden()
                    .disabled(isSaving)
                } header: {
                    Text("Model", bundle: .module)
                } footer: {
                    Text("Choosing another model downloads it if needed and reads your review history again. Until then, reviews use your usual schedule. The choice syncs with your collection.", bundle: .module)
                }
            }
        }
        .task { await poll() }
        .alert(Text(failure?.title ?? "", bundle: .module), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button(role: .cancel) { failure = nil } label: { Text("OK", bundle: .module) }
        } message: {
            Text(verbatim: failure?.message ?? "")
        }
    }

    private func optionLabel(_ model: Anki_ZzHayaki_RwkvModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch model {
            case .big:
                Text(verbatim: "Big")
                Text("The most accurate. An 11 MB download, about 26 KB of memory per card (about 9 times Small), and about 4 times slower than Small to read your review history.", bundle: .module).font(.footnote).foregroundStyle(.secondary)
            case .tiny:
                Text(verbatim: "Tiny")
                Text("A 240 KB download that reads your review history about 1.6 times faster than Small, with about the same memory per card.", bundle: .module).font(.footnote).foregroundStyle(.secondary)
            default:
                Text(verbatim: "Small")
                Text("The default. A 430 KB download and about 3 KB of memory per card.", bundle: .module).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ status: Anki_ZzHayaki_RwkvStatusResponse) -> some View {
        if status.enabled {
            switch status.state {
            case .ready:
                Label { Text("Ready. Review cards are chosen by RWKV.", bundle: .module) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            case .preparing:
                if status.total > 0 {
                    ProgressView(value: Double(status.done), total: Double(status.total)) {
                        Text("Reading Your Review History", bundle: .module)
                    }
                } else {
                    Label { Text("Downloading the Model", bundle: .module) } icon: { ProgressView() }
                }
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text("RWKV could not start, so reviews use your usual schedule.", bundle: .module)
                    Text(verbatim: status.error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    Button { retry() } label: { Text("Try Again", bundle: .module) }
                }
            default:
                Text("Waiting to Start", bundle: .module).foregroundStyle(.secondary)
            }
        }
    }

    /// Refreshes the status, every second while the core prepares.
    private func poll() async {
        while !Task.isCancelled {
            status = try? await store.rwkvStatus()
            let preparing = status.map { $0.enabled && ($0.state == .preparing || $0.state == .notPrepared) } ?? false
            try? await Task.sleep(for: preparing ? .seconds(1) : .seconds(5))
        }
    }

    private func setEnabled(_ enabled: Bool) {
        status?.enabled = enabled
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await store.setRwkvEnabled(enabled)
            } catch {
                failure = Failure(title: "Could Not Change RWKV Scheduling", message: error.localizedDescription)
            }
            status = try? await store.rwkvStatus()
        }
    }

    private func setModel(_ model: Anki_ZzHayaki_RwkvModel) {
        status?.model = model
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await store.setRwkvModel(model)
            } catch {
                failure = Failure(title: "Could Not Change the RWKV Model", message: error.localizedDescription)
            }
            status = try? await store.rwkvStatus()
        }
    }

    private func retry() {
        Task {
            do { try await store.prepareRwkv() } catch { failure = Failure(title: "Could Not Change RWKV Scheduling", message: error.localizedDescription) }
            status = try? await store.rwkvStatus()
        }
    }
}
