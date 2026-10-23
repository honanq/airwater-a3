import SwiftUI

/// Liquid surface filling a container from the bottom.
struct WaveShape: Shape {
    var level: Double          // 0…1
    var amplitude: Double
    var phase: Double
    var frequency: Double = 1.3

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(level, amplitude) }
        set { level = newValue.first; amplitude = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let surface = rect.maxY - rect.height * min(max(level, 0), 1)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: surface))
        for x in stride(from: 0, through: rect.width, by: 3) {
            let relative = x / rect.width
            let y = surface + sin(relative * .pi * 2 * frequency + phase) * amplitude
            path.addLine(to: CGPoint(x: rect.minX + x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Two layered waves that drift continuously; calmer when the device is idle.
struct LiquidFill: View {
    var level: Double
    var active: Bool
    var tint: Color = Mist.aqua
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = PhaseClock()

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let phase = clock.advance(timeline.date.timeIntervalSinceReferenceDate, speed: active ? 2.4 : 0.8)
            ZStack {
                WaveShape(level: level, amplitude: active ? 7 : 3, phase: phase * 1.3 + 1.8, frequency: 1.1)
                    .fill(tint.opacity(0.22))
                WaveShape(level: level - 0.02, amplitude: active ? 5 : 2, phase: phase, frequency: 1.5)
                    .fill(LinearGradient(colors: [tint.opacity(0.55), Mist.teal.opacity(0.35)],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
        .animation(.spring(response: 1.1, dampingFraction: 0.8), value: level)
        .animation(.easeInOut(duration: 0.8), value: active)
    }
}

/// Expanding rings, fired once per `trigger` change. Used as the "applied" cue.
struct RippleBurst: View {
    var trigger: Int
    var color: Color = Mist.mint
    @State private var waves: [Int] = []

    var body: some View {
        ZStack {
            ForEach(waves, id: \.self) { wave in
                RippleRing(color: color, delay: 0)
                    .id("\(wave)-a")
                RippleRing(color: color, delay: 0.18)
                    .id("\(wave)-b")
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { value in
            waves.append(value)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                waves.removeAll { $0 == value }
            }
        }
    }
}

private struct RippleRing: View {
    var color: Color
    var delay: Double
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: expanded ? 0.5 : 5)
            .scaleEffect(expanded ? 1.45 : 0.92)
            .opacity(expanded ? 0 : 0.85)
            .onAppear {
                withAnimation(.easeOut(duration: 1.25).delay(delay)) { expanded = true }
            }
    }
}

/// 270° humidity dial with a liquid core and a target-humidity marker.
struct HumidityGauge: View {
    var humidity: Double?      // percent
    var target: Int?           // percent
    var active: Bool
    var caption: String
    var applyPulse: Int
    var size: CGFloat = 264

    private let sweep = 0.75
    private var fraction: Double { min(max((humidity ?? 0) / 100, 0), 1) }

    var body: some View {
        ZStack {
            ticks
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(10)
            Circle()
                .trim(from: 0, to: sweep * fraction)
                .stroke(AngularGradient(colors: [Mist.teal, Mist.aqua, Mist.mint],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(270 * fraction + 1)),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(10)
                .shadow(color: Mist.aqua.opacity(0.55), radius: 10)
                .animation(.spring(response: 1.0, dampingFraction: 0.78), value: fraction)
            if let target, (0...100).contains(target) { targetMarker(target) }
            core
            RippleBurst(trigger: applyPulse)
                .frame(width: size - 84, height: size - 84)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        var text = humidity.map { String(format: "%.1f%%", $0) } ?? "未知"
        if let target { text += "，目标 \(target)%" }
        return text
    }

    private var ticks: some View {
        ZStack {
            ForEach(0..<41, id: \.self) { index in
                let position = Double(index) / 40
                let lit = position <= fraction && humidity != nil
                Capsule()
                    .fill(Color.white.opacity(lit ? 0.55 : 0.14))
                    .frame(width: index % 5 == 0 ? 2.5 : 1.5, height: index % 5 == 0 ? 10 : 5)
                    .offset(y: -(size / 2 - 31))
                    .rotationEffect(.degrees(-135 + 270 * position))
            }
        }
        .animation(.easeOut(duration: 0.6), value: fraction)
    }

    private func targetMarker(_ target: Int) -> some View {
        let radius = size / 2 - 10
        let angle = (135 + 270 * Double(target) / 100) * .pi / 180
        return ZStack {
            Circle().fill(Mist.amber.opacity(0.35)).frame(width: 22, height: 22)
            Circle().fill(Mist.amber).frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
        }
        .offset(x: radius * cos(angle), y: radius * sin(angle))
        .animation(.spring(response: 0.8, dampingFraction: 0.7), value: target)
    }

    private var core: some View {
        let inner = size - 84
        return ZStack {
            Circle().fill(Color.white.opacity(0.04))
            LiquidFill(level: humidity == nil ? 0.12 : fraction, active: active)
                .clipShape(Circle())
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(humidity.map { String(format: "%.0f", $0) } ?? "--")
                        .font(Mist.rounded(68, .bold))
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: humidity)
                    Text("%").font(Mist.rounded(24, .semibold)).foregroundStyle(Mist.secondary)
                }
                .shimmer(humidity == nil)
                Text(caption).font(Mist.rounded(13, .medium)).foregroundStyle(Mist.secondary)
                if let target {
                    Label("目标 \(target)%", systemImage: "scope")
                        .font(Mist.rounded(12, .semibold))
                        .foregroundStyle(Mist.amber)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Mist.amber.opacity(0.14)))
                        .padding(.top, 6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(.white)
        }
        .frame(width: inner, height: inner)
    }
}
