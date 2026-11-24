import AnkiProto
import CollectionStore
import SwiftUI

/// The RWKV scheduling switch and its status (ADR 0007).
struct RwkvSchedulingSection: View {
    let store: CollectionStore
    @State private var status: Anki_ZzHayaki_RwkvStatusResponse?
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Review cards come due when an RWKV model predicts that your chance of recalling them has fallen to the deck's desired retention. New and learning cards, and every due date Anki stores, are unchanged, so turning this off returns to your usual schedule at once.", bundle: .module)
                Text("The switch syncs with your collection. If another device changes any preference later and syncs first, it can turn the switch back.", bundle: .module)
                Text("Turning it on downloads the model (about 430 KB). Its author allows personal and research use.", bundle: .module)
            }
        }
        .task { await poll() }
        .alert(Text("Could Not Change RWKV Scheduling", bundle: .module), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button(role: .cancel) { error = nil } label: { Text("OK", bundle: .module) }
        } message: {
            Text(verbatim: error ?? "")
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
                self.error = error.localizedDescription
            }
            status = try? await store.rwkvStatus()
        }
    }

    private func retry() {
        Task {
            do { try await store.prepareRwkv() } catch { self.error = error.localizedDescription }
            status = try? await store.rwkvStatus()
        }
    }
}
