import SwiftUI

/// A message inside the window, for something Max should know that does not
/// stop him from working: a glass bar at the top of the timeline with a
/// warning triangle, one sentence, and a button that closes it.
/// `MainLayout` shows it when its content has a `message`.
///
///     MessageBanner("Lockstep could not find beats in this song.") { message = nil }
///
/// Something that must be answered before work goes on is an alert instead:
/// see `messageAlert`.
///
/// It is as wide as its sentence, up to
/// `DesignTokens.Sizes.messageBannerMaximumWidth`. A longer sentence ends in
/// an ellipsis, with the whole sentence in the help tag.
public struct MessageBanner: View {
    private let message: String
    private let close: () -> Void

    /// - Parameters:
    ///   - message: One sentence, with its full stop.
    ///   - close: Called when the close button is pressed.
    public init(_ message: String, close: @escaping () -> Void = {}) {
        self.message = message
        self.close = close
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DesignTokens.Fonts.symbol)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .accessibilityHidden(true)
            Text(message)
                .font(DesignTokens.Fonts.label)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
            SymbolButton(
                symbol: "xmark",
                name: "Close",
                font: DesignTokens.Fonts.symbolSmall,
                color: DesignTokens.Colors.textSecondary,
                action: close
            )
        }
        .padding(.leading, DesignTokens.Spacing.barPadding)
        .padding(.trailing, DesignTokens.Spacing.medium)
        .frame(height: DesignTokens.Sizes.messageBannerHeight)
        .glassCapsule()
        // The glass is as wide as the sentence. This only keeps a long
        // sentence from making it wider than the limit.
        .frame(maxWidth: DesignTokens.Sizes.messageBannerMaximumWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}

/// What an alert says.
public struct MessageAlert: Sendable, Equatable {
    /// The one sentence that says what happened, such as "Lockstep could not
    /// read this file."
    public var title: String
    /// A sentence or two under it: why, and what to do. Empty leaves it out.
    public var detail: String

    public init(title: String, detail: String = "") {
        self.title = title
        self.detail = detail
    }
}

extension View {
    /// Shows the system's alert with one OK button, for something that must
    /// be read before work goes on, such as a file that could not be opened.
    /// It is the system's own alert, in the dark look of the window.
    ///
    ///     .messageAlert(MessageAlert(title: "Lockstep could not read this file."), isPresented: $showsAlert)
    public func messageAlert(_ alert: MessageAlert, isPresented: Binding<Bool>) -> some View {
        self.alert(alert.title, isPresented: isPresented) {
            Button("OK") {}
        } message: {
            if !alert.detail.isEmpty {
                Text(alert.detail)
            }
        }
    }
}
