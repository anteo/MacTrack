import SwiftUI

/// A small circular glass button for header/footer actions.
struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 28
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                // Keep the symbol's contrast steady. The glass itself supplies the
                // hover affordance; a white glyph looks like an accidental active
                // state against this light panel.
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Theme.Ink.primary.opacity(hovering ? 0.10 : 0))
                )
                // Non-interactive glass: it's a visual material only, so it never
                // intercepts the click (the interactive variant was swallowing taps).
                .glassEffect(.regular, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(help)
    }
}

/// Compact icon-only selector for the graph modes. The symbols are intentionally
/// paired with help text so the control stays quiet without becoming ambiguous.
struct GraphModeSelector: View {
    @Binding var selection: String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageChartMode.allCases) { mode in
                let isSelected = selection == mode.rawValue
                Button {
                    withAnimation(.pill) { selection = mode.rawValue }
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.tertiary)
                        .frame(width: 30, height: 25)
                        .contentShape(Rectangle())
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(Theme.fill(2))
                                    .overlay(Capsule(style: .continuous)
                                        .strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "graph-pill", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(3)
        .background(Theme.fill(0), in: Capsule(style: .continuous))
    }
}

/// Section label in the small-caps tracked style used across the app.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2Strong)
            .tracking(0.6)
            .foregroundStyle(Theme.Ink.tertiary)
    }
}
