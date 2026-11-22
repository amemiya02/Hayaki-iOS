import SwiftUI

/// How the deck list draws over a background image: how much the screen's
/// background colour veils the image, and how solid the deck rows are.
/// Device preferences, like the image itself.
public enum DeckBackgroundStyle {
    public static let dimmingKey = "hayaki.deckBackground.dimming"
    public static let rowOpacityKey = "hayaki.deckBackground.rowOpacity"
    public static let defaultDimming = 0.25
    public static let defaultRowOpacity = 0.65
}

/// A deck row's surface over the background image: clear at 0, frosted
/// glass by 0.5, and the usual solid row colour at 1.
public struct DeckRowSurface: View {
    private let opacity: Double
    @Environment(\.hayakiTheme) private var theme

    public init(opacity: Double) {
        self.opacity = opacity
    }

    public var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .opacity(min(1, opacity * 2))
            .overlay(theme.surface.opacity(max(0, opacity * 2 - 1)))
    }
}
