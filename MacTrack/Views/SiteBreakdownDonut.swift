import SwiftUI

/// A multi-slice ring in the exact style of `ProductivityDonut` — same thickness,
/// rounded activity-ring segments, gaps, glow, hover-grow, and legend — but for an
/// arbitrary set of slices, each in its own color. Used on a browser app's detail
/// to show the websites that make up its time, each slice in the site's live
/// favicon brand color. Reuses `ProductivityDonut.allocate` / `.percentages` so the
/// proportions and legend math match the productivity donut precisely.
struct SiteBreakdownDonut: View {
    struct Slice: Identifiable {
        let id: String          // "site:domain" or "other"
        let name: String
        let seconds: Double
        var color: Color        // var so the distinctness pass can nudge it
        var drillable: Bool = true   // "Other sites" has no single per-hour series
    }

    let slices: [Slice]
    /// Per-hour minutes for a tapped slice, so tapping a website swaps the legend for
    /// that site's hourly bar chart. Supplied by the parent (which owns the store).
    var hourlyBars: (Slice) -> [(hour: Int, minutes: Double)] = { _ in [] }
    /// Per-day seconds for a tapped slice across history, for its activity grid.
    var dailyActivity: (Slice) -> [String: Double] = { _ in [:] }

    /// The drilled-in view can show either the per-hour bar chart or a GitHub-style
    /// activity grid of the site across every past day.
    enum DrillMode: String, CaseIterable, Identifiable {
        case chart = "Chart", activity = "Activity"
        var id: String { rawValue }
    }

    @State private var hovered: Int? = nil
    @State private var selected: Int? = nil
    @State private var cursorActive = false
    @State private var drillMode: DrillMode = .chart
    @State private var activityDaily: [String: Double] = [:]

    private let drillCurve: Animation = .timingCurve(0.22, 1, 0.36, 1, duration: 0.3)

    private let lineWidth: CGFloat = 14
    private let hoverWidth: CGFloat = 18
    private let gap: Double = 0.05

    private var total: Double { slices.reduce(0) { $0 + $1.seconds } }
    private var pct: [Int] { ProductivityDonut.percentages(slices.map(\.seconds)) }

    var body: some View {
        VStack(spacing: 16) {
            ring
                .frame(width: 156, height: 156)
                .frame(width: 184, height: 184)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { handleHover($0) }
                .onTapGesture { tapRing() }
                .onDisappear { if cursorActive { NSCursor.pop(); cursorActive = false } }

            // Tap a slice to swap the legend for that site's per-hour bar chart.
            ZStack {
                if let sel = selected, sel < slices.count {
                    drill(sel).id(sel).transition(.opacity)
                } else {
                    legend.transition(.opacity)
                }
            }
            .animation(drillCurve, value: selected)
        }
        .frame(maxWidth: .infinity)
    }

    private var ring: some View {
        ZStack {
            if total > 0 { segments }
            else { Circle().stroke(Color.white.opacity(0.06), lineWidth: lineWidth) }
            center
        }
    }

    private var segments: some View {
        let layout = sliceLayout
        let useGap = layout.count > 1
        let arcs: [(from: Double, to: Double, color: Color, index: Int)] = layout.map { s in
            let inset = useGap ? gap / 2 : 0
            let from = s.start + inset
            let to = max(from + 0.004, s.end - inset)
            return (from, to, s.color, s.index)
        }
        return ZStack {
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                let hot = hovered == arc.index || selected == arc.index
                Circle()
                    .trim(from: arc.from, to: arc.to)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: hot ? hoverWidth : lineWidth, lineCap: .round))
                    .shadow(color: arc.color.opacity(hot ? 0.55 : 0.36), radius: hot ? 5 : 3)
                    .shadow(color: arc.color.opacity(hot ? 0.34 : 0.18), radius: hot ? 14 : 8)
                    .rotationEffect(.degrees(-90))
            }
        }
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.28), value: hovered)
    }

    /// Each slice's `[start, end]` span, with a minimum arc so a tiny slice still
    /// draws — same allocation the productivity donut uses.
    private var sliceLayout: [(index: Int, start: Double, end: Double, color: Color)] {
        guard total > 0 else { return [] }
        let nz = slices.enumerated().filter { $0.element.seconds > 0 }
        guard !nz.isEmpty else { return [] }
        let minA = nz.count > 1 ? gap + 0.035 : 0
        let alloc = ProductivityDonut.allocate(nz.map { $0.element.seconds / total }, minA: minA)
        var cursor = 0.0
        var out: [(index: Int, start: Double, end: Double, color: Color)] = []
        for (k, item) in nz.enumerated() {
            out.append((item.offset, cursor, cursor + alloc[k], item.element.color))
            cursor += alloc[k]
        }
        return out
    }

    private var center: some View {
        VStack(spacing: 1) {
            if let i = hovered ?? selected, i < slices.count, total > 0 {
                Text("\(pct[i])%")
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.Ink.primary)
                    .contentTransition(.numericText())
                Text(slices[i].name)
                    .font(.caption2Strong).foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1).contentTransition(.opacity)
            } else if total > 0 {
                Text(Format.duration(total))
                    .font(.system(size: 23, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Ink.primary)
                Text("total").font(.caption2Strong).foregroundStyle(Theme.Ink.tertiary)
            } else {
                Text("—").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.Ink.tertiary)
                Text("no sites yet").font(.caption2Strong).foregroundStyle(Theme.Ink.faint)
            }
        }
        .animation(.smooth(duration: 0.3), value: hovered)
        .animation(.smooth(duration: 0.3), value: selected)
    }

    /// The drilled-in view: a back header (chevron + site + its %/time) over the
    /// site's per-hour bar chart, in the site's own color.
    private func drill(_ i: Int) -> some View {
        let s = slices[i]
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(drillCurve) { selected = nil }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Ink.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(s.color).frame(width: 9, height: 9)
                Text(s.name).font(.rowTitle).foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(total > 0 ? pct[i] : 0)%")
                    .font(.rowMeta.monospacedDigit()).foregroundStyle(Theme.Ink.tertiary)
                Text(Format.duration(s.seconds))
                    .font(.rowValue.monospacedDigit()).foregroundStyle(Theme.Ink.primary)
            }
            .padding(.bottom, 8)

            // A slider under the site name: per-hour chart, or its all-time activity grid.
            HStack {
                modeToggle
                Spacer()
            }
            .padding(.bottom, 8)

            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.bottom, 8)

            ZStack {
                if drillMode == .chart {
                    HourBarChart(bars: hourlyBars(s), color: s.color).transition(.opacity)
                } else {
                    SiteActivityGraph(color: s.color, daily: activityDaily).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: drillMode)
            .task(id: "\(s.id)|\(drillMode == .activity)") {
                if drillMode == .activity { activityDaily = dailyActivity(s) }
            }
        }
        .padding(.horizontal, 4)
    }

    private var modeToggle: some View {
        HStack(spacing: 3) {
            ForEach(DrillMode.allCases) { m in
                let sel = drillMode == m
                Button { withAnimation(.easeOut(duration: 0.2)) { drillMode = m } } label: {
                    Text(m.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(sel ? Theme.Ink.primary : Theme.Ink.tertiary)
                        .lineLimit(1).fixedSize()
                        .padding(.vertical, 5).padding(.horizontal, 11)
                        .background {
                            if sel {
                                Capsule(style: .continuous).fill(Theme.fill(2))
                                    .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.fill(0), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var legend: some View {
        VStack(spacing: 8) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(s.color)
                        .frame(width: 9, height: 9)
                    Text(s.name)
                        .font(.rowTitle).foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text("\(total > 0 ? pct[i] : 0)%")
                        .font(.rowMeta.monospacedDigit()).foregroundStyle(Theme.Ink.tertiary)
                        .contentTransition(.numericText())
                    Text(Format.duration(s.seconds))
                        .font(.rowValue.monospacedDigit()).foregroundStyle(Theme.Ink.primary)
                        .frame(minWidth: 54, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                .opacity(hovered == nil || hovered == i ? 1 : 0.5)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .contentShape(Rectangle())
                .onHover { h in hovered = h ? i : (hovered == i ? nil : hovered) }
                .onTapGesture { if s.drillable { withAnimation(drillCurve) { selected = i } } }
            }
        }
        .padding(.horizontal, 4)
    }

    private func tapRing() {
        if let h = hovered, slices[h].drillable {
            withAnimation(drillCurve) { selected = (selected == h) ? nil : h }
        } else if selected != nil {
            withAnimation(drillCurve) { selected = nil }
        }
    }

    private func handleHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let p):
            let idx = sliceIndex(at: p)
            hovered = idx
            let drillable = idx.map { slices[$0].drillable } ?? false
            if drillable && !cursorActive { NSCursor.pointingHand.push(); cursorActive = true }
            else if !drillable && cursorActive { NSCursor.pop(); cursorActive = false }
        case .ended:
            hovered = nil
            if cursorActive { NSCursor.pop(); cursorActive = false }
        }
    }

    private func sliceIndex(at p: CGPoint) -> Int? {
        guard total > 0 else { return nil }
        let c = 92.0
        let dx = Double(p.x) - c, dy = Double(p.y) - c
        let r = (dx * dx + dy * dy).squareRoot()
        guard r >= 54, r <= 96 else { return nil }
        let ang = atan2(dy, dx) * 180 / .pi
        var f = (ang + 90).truncatingRemainder(dividingBy: 360)
        if f < 0 { f += 360 }
        let frac = f / 360
        for s in sliceLayout where frac >= s.start && frac < s.end { return s.index }
        return nil
    }

    // MARK: - Color distinctness

    /// Nudge slice colors so no two *adjacent* arcs (including the wrap from last to
    /// first, since it's a ring) read as the same color. Grayscale slices (e.g.
    /// "Other") are left alone; a saturated slice too close in hue to its neighbor is
    /// rotated around the color wheel until it separates.
    static func distinctColors(_ slices: [Slice]) -> [Slice] {
        guard slices.count > 1 else { return slices }
        var out = slices
        for i in 1..<out.count {
            out[i].color = separated(out[i].color, avoiding: [out[i - 1].color])
        }
        if out.count > 2 {
            out[out.count - 1].color = separated(out[out.count - 1].color,
                                                 avoiding: [out[0].color, out[out.count - 2].color])
        }
        return out
    }

    private static func separated(_ color: Color, avoiding neighbors: [Color]) -> Color {
        guard let base = hsb(color), base.s >= 0.2 else { return color }   // leave grays
        let avoidHues = neighbors.compactMap(hsb).filter { $0.s >= 0.2 }.map(\.h)
        guard !avoidHues.isEmpty else { return color }
        var hue = base.h
        var tries = 0
        while tries < 7, avoidHues.contains(where: { hueDistance(hue, $0) < 0.075 }) {
            hue = (hue + 0.13).truncatingRemainder(dividingBy: 1)
            tries += 1
        }
        guard tries > 0 else { return color }
        return Color(hue: hue, saturation: base.s, brightness: base.b)
    }

    private static func hsb(_ color: Color) -> (h: Double, s: Double, b: Double)? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (Double(ns.hueComponent), Double(ns.saturationComponent), Double(ns.brightnessComponent))
    }
    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }
}

/// The site's all-time activity grid: the shared `ActivityGraph`, but every day is
/// shaded in the site's own color — the busiest day at full color (its brightest,
/// lightest shade on the dark panel), quieter days dimmer, no-data days a faint gray
/// — exactly like GitHub's green scale, in the site's dynamic color instead.
private struct SiteActivityGraph: View {
    let color: Color
    let daily: [String: Double]      // day key → seconds on this site

    private var maxV: Double { max(daily.values.max() ?? 1, 1) }

    var body: some View {
        ActivityGraph(
            fillFor: { key in
                guard let v = daily[key], v > 0 else { return nil }
                // Four shades like GitHub: the peak day gets the full color, quieter
                // days step down toward the background.
                let t = v / maxV
                let level: Double = t < 0.25 ? 0.34 : t < 0.5 ? 0.55 : t < 0.75 ? 0.76 : 1.0
                return color.opacity(level)
            },
            tooltip: { key in
                guard let v = daily[key] else { return "" }
                return Self.dayLabel(key) + " · " + Format.duration(v)
            },
            interactive: false)
    }

    private static let fmtIn: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let fmtOut: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
    private static func dayLabel(_ key: String) -> String {
        guard let d = fmtIn.date(from: key) else { return key }
        return fmtOut.string(from: d)
    }
}
