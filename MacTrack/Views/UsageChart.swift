import SwiftUI
import AppKit

/// A clean line chart of cumulative time spent across the day for the top items
/// of the current scope. X = clock time (configurable window), Y = minutes.
/// Minimal grid, ten muted colors, draw-in animation, and a hover scrubber with
/// an exact-value tooltip. The matching list rows act as the color legend.
struct UsageChartView: View {
    let lines: [ChartLineData]
    let startMinute: Int
    let endMinute: Int

    @State private var drawProgress: CGFloat = 0
    @State private var hoverPoint: CGPoint?

    // Plot insets.
    private let leftGutter: CGFloat = 30
    private let bottomGutter: CGFloat = 16
    private let topPad: CGFloat = 10
    private let rightPad: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                grid(w, h)
                axisLabels(w, h)
                linesLayer(w, h)
                hoverLayer(w, h)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverPoint = p
                case .ended: hoverPoint = nil
                }
            }
        }
        .frame(height: 132)
        .onAppear {
            drawProgress = 0
            withAnimation(.easeOut(duration: 0.55)) { drawProgress = 1 }
        }
    }

    // MARK: Scales

    private var yMax: Double {
        let maxTotal = lines.map(\.totalMinutes).max() ?? 0
        guard maxTotal > 0 else { return 1 }
        let steps: [Double] = [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480, 600, 720, 840]
        return steps.first { $0 >= maxTotal } ?? ((maxTotal / 60).rounded(.up) * 60)
    }

    private func xPix(_ minute: Double, _ w: CGFloat) -> CGFloat {
        let span = Double(endMinute - startMinute)
        let frac = span > 0 ? (minute - Double(startMinute)) / span : 0
        return leftGutter + CGFloat(frac) * (w - leftGutter - rightPad)
    }
    private func yPix(_ minutes: Double, _ h: CGFloat) -> CGFloat {
        let plotH = h - topPad - bottomGutter
        let frac = yMax > 0 ? minutes / yMax : 0
        return topPad + plotH * (1 - CGFloat(frac))
    }

    // MARK: Grid + axes

    private var hourTicks: [Int] {
        let startHour = startMinute / 60, endHour = endMinute / 60
        let totalH = max(1, endHour - startHour)
        let step = max(1, Int((Double(totalH) / 4.0).rounded()))
        var ticks: [Int] = []
        var hr = startHour
        while hr < endHour { ticks.append(hr); hr += step }
        ticks.append(endHour)
        return ticks
    }
    private var yTicks: [Double] { [0, yMax / 2, yMax] }

    private func grid(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            ForEach(yTicks, id: \.self) { v in
                Path { p in
                    let y = yPix(v, h)
                    p.move(to: CGPoint(x: leftGutter, y: y))
                    p.addLine(to: CGPoint(x: w - rightPad, y: y))
                }
                .stroke(Theme.hairline, lineWidth: 0.5)
            }
        }
    }

    private func axisLabels(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(yTicks, id: \.self) { v in
                Text("\(Int(v))m")
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.Ink.faint)
                    .position(x: leftGutter - 14, y: yPix(v, h))
            }
            ForEach(hourTicks, id: \.self) { hr in
                Text(hourLabel(hr))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Theme.Ink.faint)
                    .position(x: xPix(Double(hr * 60), w), y: h - 6)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ap = (hour >= 12 && hour < 24) ? "P" : "A"
        return "\(h12)\(ap)"
    }

    // MARK: Lines

    private func linesLayer(_ w: CGFloat, _ h: CGFloat) -> some View {
        let highlighted = nearestLine(w, h)?.id
        return ZStack {
            ForEach(lines) { line in
                linePath(line, w, h)
                    .trim(from: 0, to: drawProgress)
                    .stroke(line.color,
                            style: StrokeStyle(lineWidth: highlighted == line.id ? 2.2 : 1.6,
                                               lineCap: .round, lineJoin: .round))
                    .opacity(highlighted == nil || highlighted == line.id ? 1 : 0.18)
            }
        }
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }

    private func linePath(_ line: ChartLineData, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path { p in
            for (i, pt) in line.points.enumerated() {
                let cg = CGPoint(x: xPix(pt.x, w), y: yPix(pt.y, h))
                if i == 0 { p.move(to: cg) } else { p.addLine(to: cg) }
            }
        }
    }

    // MARK: Hover

    private func minuteAt(_ x: CGFloat, _ w: CGFloat) -> Int {
        let span = Double(endMinute - startMinute)
        let frac = Double((x - leftGutter) / (w - leftGutter - rightPad))
        return min(max(startMinute, Int(Double(startMinute) + frac * span)), endMinute)
    }

    /// Interpolated Y (minutes) of a line at a given minute.
    private func value(_ line: ChartLineData, at minute: Double) -> Double {
        let pts = line.points
        guard let first = pts.first else { return 0 }
        if minute <= Double(first.x) { return Double(first.y) }
        for i in 1..<pts.count {
            if minute <= Double(pts[i].x) {
                let ax = Double(pts[i - 1].x), ay = Double(pts[i - 1].y)
                let bx = Double(pts[i].x), by = Double(pts[i].y)
                let t = bx == ax ? 0 : (minute - ax) / (bx - ax)
                return ay + (by - ay) * t
            }
        }
        return Double(pts.last?.y ?? 0)
    }

    private func nearestLine(_ w: CGFloat, _ h: CGFloat) -> ChartLineData? {
        guard let pt = hoverPoint, !lines.isEmpty else { return nil }
        let minute = Double(minuteAt(pt.x, w))
        return lines.min { a, b in
            abs(yPix(value(a, at: minute), h) - pt.y) < abs(yPix(value(b, at: minute), h) - pt.y)
        }
    }

    private func hoverLayer(_ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            if let pt = hoverPoint {
                let minute = minuteAt(pt.x, w)
                let x = xPix(Double(minute), w)
                let near = nearestLine(w, h)

                // Vertical scrubber.
                Path { p in
                    p.move(to: CGPoint(x: x, y: topPad))
                    p.addLine(to: CGPoint(x: x, y: h - bottomGutter))
                }
                .stroke(Theme.hairlineStrong, lineWidth: 1)

                // A dot where each line crosses the scrubber.
                ForEach(lines) { line in
                    Circle()
                        .fill(line.color)
                        .frame(width: near?.id == line.id ? 7 : 5, height: near?.id == line.id ? 7 : 5)
                        .opacity(near == nil || near?.id == line.id ? 1 : 0.3)
                        .position(x: x, y: yPix(value(line, at: Double(minute)), h))
                }

                if let near {
                    tooltip(for: near, minute: minute, x: x, w: w)
                }
            }
        }
    }

    private func tooltip(for line: ChartLineData, minute: Int, x: CGFloat, w: CGFloat) -> some View {
        let value = self.value(line, at: Double(minute))
        let tipWidth: CGFloat = 132
        let clampedX = min(max(leftGutter + tipWidth / 2, x), w - rightPad - tipWidth / 2)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(line.color).frame(width: 6, height: 6)
                Text(line.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
            }
            Text("\(Int(value.rounded()))m · \(clockLabel(minute))")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Ink.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: tipWidth, alignment: .leading)
        .background(Theme.fill(2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .position(x: clampedX, y: topPad + 14)
    }

    private func clockLabel(_ minute: Int) -> String {
        let hour = minute / 60, min = minute % 60
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ap = (hour >= 12 && hour < 24) ? "PM" : "AM"
        return String(format: "%d:%02d %@", h12, min, ap)
    }
}

struct HourlyStackedChartView: View {
    let buckets: [HourlyChartBucket]
    let startHour: Int
    let endHour: Int
    @State private var hoverHour: Int?
    @State private var hoveredSegmentID: String?

    private let leftGutter: CGFloat = 30
    private let rightPad: CGFloat = 8
    private let topPad: CGFloat = 8
    private let bottomGutter: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                ForEach([0, 30, 60], id: \.self) { value in
                    Path { p in
                        let y = yPix(Double(value), h)
                        p.move(to: CGPoint(x: leftGutter, y: y)); p.addLine(to: CGPoint(x: w - rightPad, y: y))
                    }.stroke(Theme.hairline, lineWidth: 0.5)
                    Text("\(value)m").font(.system(size: 8.5).monospacedDigit()).foregroundStyle(Theme.Ink.faint)
                        .position(x: leftGutter - 14, y: yPix(Double(value), h))
                }
                ForEach(buckets) { bucket in
                    let x = xPix(bucket.hour, w)
                    let barWidth = max(3, (w - leftGutter - rightPad) / CGFloat(max(1, endHour - startHour)) - 3)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach(Array(bucket.segments.enumerated()), id: \.offset) { _, segment in
                            let isHovered = hoveredSegmentID == "\(bucket.hour)|\(segment.id)"
                            Rectangle().fill(segment.color.opacity(hoveredSegmentID == nil ? 0.9 : (isHovered ? 1 : 0.22)))
                                .frame(height: CGFloat(segment.minutes / 60) * (h - topPad - bottomGutter))
                                .onHover { isHovering in
                                    hoveredSegmentID = isHovering ? "\(bucket.hour)|\(segment.id)" : nil
                                }
                        }
                    }
                    .frame(width: barWidth, height: h - bottomGutter, alignment: .bottom)
                    .position(x: x + barWidth / 2, y: topPad + (h - topPad - bottomGutter) / 2)
                    Text(hourLabel(bucket.hour)).font(.system(size: 8.5)).foregroundStyle(Theme.Ink.faint)
                        .position(x: x + barWidth / 2, y: h - 6)
                }
                if let hover = hoveredSegment {
                    ChartTooltipCard {
                        HStack(spacing: 5) {
                            Circle().fill(hover.color).frame(width: 7, height: 7)
                            Text(hover.label)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text("\(Int(hover.minutes.rounded()))m · \(hourLabel(hover.hour))")
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.Ink.tertiary)
                    }
                        .allowsHitTesting(false)
                        .position(x: tooltipX(for: hover.hour, width: w), y: tooltipY(for: hover, height: h))
                }
            }
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.18), value: hoveredSegmentID)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let span = CGFloat(max(1, endHour - startHour))
                    hoverHour = min(endHour - 1, max(startHour, startHour + Int((point.x - leftGutter) / max(1, (w - leftGutter - rightPad) / span))))
                case .ended:
                    hoverHour = nil
                    hoveredSegmentID = nil
                }
            }
        }
        .frame(height: 132)
    }

    private var hoveredSegment: (hour: Int, id: String, label: String, color: Color, minutes: Double)? {
        guard let key = hoveredSegmentID,
              let separator = key.firstIndex(of: "|"),
              let hour = Int(key[..<separator]),
              let bucket = buckets.first(where: { $0.hour == hour }) else { return nil }
        let id = String(key[key.index(after: separator)...])
        guard let segment = bucket.segments.first(where: { $0.id == id }) else { return nil }
        return (hour, segment.id, segment.label, segment.color, segment.minutes)
    }

    private func tooltipX(for hour: Int, width: CGFloat) -> CGFloat {
        min(max(76, xPix(hour, width) + 24), width - 76)
    }

    private func tooltipY(for hover: (hour: Int, id: String, label: String, color: Color, minutes: Double), height: CGFloat) -> CGFloat {
        guard let bucket = buckets.first(where: { $0.hour == hover.hour }) else { return 18 }
        guard let index = bucket.segments.firstIndex(where: { $0.id == hover.id }) else { return 18 }
        // The VStack lays the first segment at the top of the stack and the last
        // at the baseline, so measure from this segment through the final one.
        let minutesToBaseline = bucket.segments[index...].reduce(0.0) { $0 + $1.minutes }
        let segmentTop = yPix(min(60, minutesToBaseline), height)
        // Keep the tooltip close to the segment without reserving permanent space
        // above the chart. SwiftUI allows the hover overlay to float outward.
        return segmentTop - 20
    }

    private func xPix(_ hour: Int, _ width: CGFloat) -> CGFloat {
        leftGutter + CGFloat(hour - startHour) / CGFloat(max(1, endHour - startHour)) * (width - leftGutter - rightPad)
    }
    private func yPix(_ minutes: Double, _ height: CGFloat) -> CGFloat {
        topPad + (height - topPad - bottomGutter) * (1 - CGFloat(minutes / 60))
    }
    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h)\((hour >= 12 && hour < 24) ? "P" : "A")"
    }
}

struct WorkdayChartView: View {
    let segments: [WorkdayChartSegment]
    let startMinute: Int
    let endMinute: Int
    @State private var hoveredSegmentID: String?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Active timeline").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.Ink.secondary)
                    Spacer()
                    Text(activeLabel).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.Ink.tertiary)
                }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.fill(1))
                    ForEach(segments) { segment in
                        Rectangle().fill(segment.color.opacity(hoveredSegmentID == nil ? 1 : (hoveredSegmentID == segment.id ? 1 : 0.22)))
                            .frame(width: max(2, x(segment.endMinute, width: width) - x(segment.startMinute, width: width)), height: 38)
                            .offset(x: x(segment.startMinute, width: width))
                            .onHover { isHovering in
                                hoveredSegmentID = isHovering ? segment.id : nil
                            }
                    }
                }
                .frame(height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let segment = segments.first(where: { $0.id == hoveredSegmentID }) {
                        ChartTooltipCard {
                            HStack(spacing: 5) {
                                Circle().fill(segment.color).frame(width: 7, height: 7)
                                Text(segment.label)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text("\(clockLabel(segment.startMinute))–\(clockLabel(segment.endMinute))")
                                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.Ink.tertiary)
                        }
                        .fixedSize()
                        .allowsHitTesting(false)
                        .position(x: min(max(72, x(segment.startMinute, width: width) + 42), width - 72), y: -26)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: hoveredSegmentID)
                .overlay(alignment: .bottomLeading) {
                    timelineTickMarks(width: width)
                        .offset(y: 10)
                        .allowsHitTesting(false)
                }
                .padding(.top, 9)
                .padding(.bottom, 6)
                HStack {
                    Text(clockLabel(startMinute)); Spacer()
                    Text(clockLabel((startMinute + endMinute) / 2)); Spacer()
                    Text(clockLabel(endMinute))
                }
                .font(.system(size: 8.5).monospacedDigit()).foregroundStyle(Theme.Ink.faint)
                HStack(spacing: 0) {
                    metric("Started", clockLabel(actualStart))
                    Spacer()
                    metric("Last active", clockLabel(actualEnd))
                    Spacer()
                    metric("Breaks", breakLabel)
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 2)
            .frame(width: width, height: geo.size.height, alignment: .top)
        }
        .frame(height: 132)
    }

    private var activeLabel: String {
        let minutes = segments.reduce(0) { $0 + $1.endMinute - $1.startMinute }
        return "\(minutes / 60)h \(minutes % 60)m active"
    }
    private var actualStart: Int { segments.first?.startMinute ?? startMinute }
    private var actualEnd: Int { segments.last?.endMinute ?? endMinute }
    private var breakLabel: String {
        let minutes = max(0, actualEnd - actualStart - segments.reduce(0) { $0 + $1.endMinute - $1.startMinute })
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    private var timelineTicks: [Int] {
        let first = ((startMinute + 29) / 30) * 30
        return Array(stride(from: first, to: endMinute, by: 30))
    }
    private func timelineTickMarks(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(timelineTicks, id: \.self) { minute in
                let isHour = minute.isMultiple(of: 60)
                Rectangle()
                    .fill(Theme.Ink.primary.opacity(0.25))
                    .frame(width: 1, height: isHour ? 8 : 4)
                    .offset(x: x(minute, width: width))
            }
        }
        .frame(width: width, height: 8, alignment: .topLeading)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8)).foregroundStyle(Theme.Ink.faint)
            Text(value).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.Ink.secondary)
        }
    }
    private func x(_ minute: Int, width: CGFloat) -> CGFloat {
        CGFloat(minute - startMinute) / CGFloat(max(1, endMinute - startMinute)) * width
    }
    private func clockLabel(_ minute: Int) -> String {
        let h = minute / 60, m = minute % 60, h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, h >= 12 ? "PM" : "AM")
    }
}

struct ChartTooltipCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2, content: content)
            .foregroundStyle(Theme.Ink.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}
