import AppKit
import Observation
import SwiftUI

struct UsageGraph: View {
    let samples: [UsageSample]
    var body: some View {
        Canvas { context, size in
            for fraction in [0.0, 0.5, 1.0] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                context.stroke(grid, with: .color(.white.opacity(0.09)), lineWidth: 1)
            }
            let ceiling = max(1024, samples.map { max($0.download, $0.upload) }.max() ?? 1024)
            for series in 0...1 {
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    let value = series == 0 ? sample.download : sample.upload
                    let point = CGPoint(
                        x: size.width * Double(UsageHistory.capacity - samples.count + index)
                            / Double(UsageHistory.capacity - 1),
                        y: size.height * (1 - min(ceiling, max(0, value)) / ceiling))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(
                    path, with: .color(series == 0 ? AmbientTheme.lavender : .mint),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityLabel(
            "Network download and upload speed, last 60 seconds, automatically scaled")
    }
}
// Scale and size live in a small observable model so resizing a desktop widget re-renders only
// that widget instead of replacing its whole hosting view hierarchy.
@MainActor @Observable final class WidgetFaceState {
    var scale: Double
    var size: NSSize
    init(scale: Double, size: NSSize) {
        self.scale = scale
        self.size = size
    }
}
struct WidgetFaceRoot: View {
    let readings: SystemReadings
    let kind: WidgetKind
    let state: WidgetFaceState
    var body: some View {
        SingleWidgetFace(readings: readings, kind: kind, scale: state.scale).frame(
            width: state.size.width, height: state.size.height)
    }
}
struct SingleWidgetFace: View {
    let readings: SystemReadings
    let kind: WidgetKind
    var scale: Double = 1
    var body: some View {
        Group {
            switch kind {
            case .clock:
                Text(readings.date, format: .dateTime.hour().minute()).font(
                    .system(size: 58 * scale, weight: .light, design: .rounded)
                ).monospacedDigit()
            case .date:
                Text(readings.date, format: .dateTime.weekday(.wide).month(.wide).day()).font(
                    .system(size: 13 * scale, weight: .medium))
            case .cpu, .memory:
                VStack(alignment: .leading, spacing: 4 * scale) {
                    Label(kind == .cpu ? "CPU" : "RAM · EST.", systemImage: kind.icon).font(
                        .system(size: 9 * scale, weight: .semibold)
                    ).foregroundStyle(AmbientTheme.lavender)
                    Text(kind == .cpu ? readings.cpuText : readings.memoryText).font(
                        .system(size: 21 * scale, weight: .medium, design: .rounded)
                    ).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14 * scale).background(
                    tile)
            case .network:
                VStack(spacing: 8 * scale) {
                    HStack {
                        Text("↓ " + readings.downloadText).foregroundStyle(AmbientTheme.lavender)
                        Spacer()
                        Text("↑ " + readings.uploadText).foregroundStyle(.mint)
                    }.font(.system(size: 10 * scale, weight: .medium)).monospacedDigit()
                    UsageGraph(samples: readings.history.samples).frame(height: 42 * scale)
                    HStack {
                        Text("NETWORK · 60s")
                        Spacer()
                        Text("500 ms")
                    }.font(.system(size: 8 * scale)).foregroundStyle(.white.opacity(0.5))
                }.padding(14 * scale).background(tile)
            case .custom: EmptyView()
            }
        }.foregroundStyle(.white).shadow(color: .black.opacity(0.4), radius: 3, y: 2)
    }
    private var tile: some View {
        RoundedRectangle(cornerRadius: 15 * scale).fill(
            Color(red: 0.10, green: 0.065, blue: 0.17).opacity(0.86)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15 * scale).stroke(AmbientTheme.lavender.opacity(0.22)))
    }
}
