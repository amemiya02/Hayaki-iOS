import HayakiAppearance
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AppearanceSettingsScreen: View {
    let background: DeckBackground
    private var settings = AppearanceSettings()
    @AppStorage(DeckBackground.revisionKey) private var backgroundRevision = ""
    @State private var choosingImage = false
    @State private var removingImage = false
    @State private var updatingImage = false
    @State private var backgroundError: String?
    @State private var photo: PhotosPickerItem?
    @State private var preview: CGImage?
    @AppStorage(DeckBackgroundStyle.dimmingKey) private var dimming = DeckBackgroundStyle.defaultDimming
    @AppStorage(DeckBackgroundStyle.rowOpacityKey) private var rowOpacity = DeckBackgroundStyle.defaultRowOpacity

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { settings.mode }, set: { settings.mode = $0 })) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        title(for: mode).tag(mode)
                    }
                } label: { Text("Appearance", bundle: .module) }
                .accessibilityIdentifier("appearance-mode")

                Picker(selection: Binding(get: { settings.systemNightMode }, set: { settings.systemNightMode = $0 })) {
                    Text("Dark", bundle: .module).tag(SystemNightMode.dark)
                    Text("Black", bundle: .module).tag(SystemNightMode.black)
                } label: { Text("Night Appearance", bundle: .module) }
                .disabled(settings.mode != .system)
            } footer: {
                Text("System uses Light when the device uses Light Mode and your night appearance in Dark Mode.", bundle: .module)
            }

            Section {
                ThemePicker(selection: Binding(get: { settings.theme }, set: { settings.theme = $0 }))
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("Theme", bundle: .module)
            }

            Section {
                BackgroundPreview(image: preview, dimming: dimming, rowOpacity: rowOpacity, updating: updatingImage)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                if preview != nil {
                    PercentSlider(value: $dimming, range: 0...0.9) {
                        Text("Image Dimming", bundle: .module)
                    }
                    .accessibilityIdentifier("background-dimming")
                    PercentSlider(value: $rowOpacity, range: 0...1) {
                        Text("Deck Row Opacity", bundle: .module)
                    }
                    .accessibilityIdentifier("deck-row-opacity")
                    if dimming != DeckBackgroundStyle.defaultDimming || rowOpacity != DeckBackgroundStyle.defaultRowOpacity {
                        Button {
                            dimming = DeckBackgroundStyle.defaultDimming
                            rowOpacity = DeckBackgroundStyle.defaultRowOpacity
                        } label: {
                            Label {
                                Text("Reset Transparency", bundle: .module)
                            } icon: { Image(systemName: "arrow.uturn.backward") }
                        }
                    }
                }
                PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                    Label {
                        Text("Choose Background Image", bundle: .module)
                    } icon: { Image(systemName: "photo.on.rectangle") }
                }
                .accessibilityIdentifier("choose-background-photo")
                Button {
                    choosingImage = true
                } label: {
                    Label {
                        Text("Choose from Files", bundle: .module)
                    } icon: { Image(systemName: "folder") }
                }
                Button(role: .destructive) {
                    removingImage = true
                } label: {
                    Text("Remove Background Image", bundle: .module)
                }
                .disabled(!background.exists)
                .id(backgroundRevision)
            } header: {
                Text("Deck List Background", bundle: .module)
            } footer: {
                Text("Decks show over the image on translucent rows.", bundle: .module)
            }
            .disabled(updatingImage)
        }
        .task(id: backgroundRevision) {
            let image = await background.image()
            if !Task.isCancelled { preview = image }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            updateBackground {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try await background.replace(with: data)
            }
        }
        .hayakiScrollBackground()
        .navigationTitle(Text("Appearance", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            updateBackground { try await background.replace(with: result.get()) }
        }
        .confirmationDialog(Text("Remove Background Image", bundle: .module), isPresented: $removingImage) {
            Button(role: .destructive) {
                do {
                    try background.remove()
                    backgroundRevision = UUID().uuidString
                } catch {
                    backgroundError = error.localizedDescription
                }
            } label: { Text("Remove Background Image", bundle: .module) }
        }
        .alert(Text("Could Not Update Background", bundle: .module), isPresented: Binding(
            get: { backgroundError != nil }, set: { if !$0 { backgroundError = nil } }
        )) {
            Button(role: .cancel) { backgroundError = nil } label: { Text("OK", bundle: .module) }
        } message: {
            Text(verbatim: backgroundError ?? "")
        }
    }

    private func updateBackground(_ replace: @escaping () async throws -> Void) {
        updatingImage = true
        Task {
            defer { updatingImage = false }
            do {
                try await replace()
                backgroundRevision = UUID().uuidString
            } catch {
                backgroundError = error.localizedDescription
            }
        }
    }

    private func title(for mode: AppearanceMode) -> Text {
        switch mode {
        case .system: Text("System", bundle: .module)
        case .light: Text("Light", bundle: .module)
        case .dark: Text("Dark", bundle: .module)
        case .black: Text("Black", bundle: .module)
        }
    }
}

/// The chosen image as the deck list shows it: behind translucent deck rows.
private struct BackgroundPreview: View {
    let image: CGImage?
    let dimming: Double
    let rowOpacity: Double
    let updating: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .overlay(HayakiBackground(.grouped).opacity(dimming))
            } else {
                HayakiBackground(.grouped)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
            }
            VStack(spacing: 0) {
                ForEach(0..<3) { index in
                    if index > 0 { Divider().padding(.leading, 12) }
                    HStack {
                        Capsule().fill(.primary.opacity(0.35)).frame(width: [72, 96, 56][index], height: 8)
                        Spacer()
                        Capsule().fill(.blue.opacity(0.7)).frame(width: 20, height: 8)
                        Capsule().fill(.green.opacity(0.7)).frame(width: 20, height: 8)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                }
            }
            .background { DeckRowSurface(opacity: rowOpacity).clipShape(.rect(cornerRadius: 10)) }
            .padding(.horizontal, 20)
            .opacity(image == nil ? 0 : 1)
            if updating {
                ProgressView().controlSize(.large)
            }
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 12))
        .animation(.easeOut(duration: 0.15), value: dimming)
        .animation(.easeOut(duration: 0.15), value: rowOpacity)
        .accessibilityElement()
        .accessibilityLabel(image == nil
            ? Text("No background image", bundle: .module)
            : Text("Background image preview", bundle: .module))
    }
}

/// A setting from 0 % to 100 %, with its value beside the name.
private struct PercentSlider<Title: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @ViewBuilder let title: () -> Title

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                title()
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: 0.05) { title() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 0.05)
            case .decrement: value = max(range.lowerBound, value - 0.05)
            @unknown default: break
            }
        }
    }
}
