import SwiftUI

struct DropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let radius = w / 2
        let centerY = rect.maxY - radius
        let k = 0.5523 * radius
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: centerY),
                      control1: CGPoint(x: rect.midX + w * 0.16, y: rect.minY + h * 0.22),
                      control2: CGPoint(x: rect.maxX, y: centerY - h * 0.22))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: centerY + k),
                      control2: CGPoint(x: rect.midX + k, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: centerY),
                      control1: CGPoint(x: rect.midX - k, y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: centerY + k))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: centerY - h * 0.22),
                      control2: CGPoint(x: rect.midX - w * 0.16, y: rect.minY + h * 0.22))
        path.closeSubpath()
        return path
    }
}

/// Hero emblem: a breathing water droplet. While connecting, ripples speed up
/// and three satellites orbit it as an indeterminate progress indicator.
struct ConnectOrb: View {
    var working: Bool
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rippleClock = PhaseClock()
    @State private var orbitClock = PhaseClock()

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let ripple = rippleClock.advance(time, speed: working ? 0.55 : 0.25)
            let orbit = orbitClock.advance(time, speed: working ? 2.4 : 0)
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let progress = (ripple + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(tint.opacity((1 - progress) * 0.55), lineWidth: 1.5)
                        .scaleEffect(0.42 + progress * 0.58)
                }
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.35), .clear], center: .center, startRadius: 10, endRadius: 110))
                if working {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == 0 ? Mist.mint : tint)
                            .frame(width: 8 - CGFloat(index) * 1.5, height: 8 - CGFloat(index) * 1.5)
                            .offset(y: -92)
                            .rotationEffect(.radians(orbit - Double(index) * 0.32))
                            .opacity(1 - Double(index) * 0.25)
                    }
                    .transition(.opacity)
                }
                droplet(time: time)
            }
            .frame(width: 220, height: 220)
        }
        .animation(.easeInOut(duration: 0.6), value: working)
        .accessibilityHidden(true)
    }

    private func droplet(time: Double) -> some View {
        let breathe = reduceMotion ? 1 : 1 + 0.035 * sin(time * (working ? 3.2 : 1.6))
        return ZStack {
            DropletShape().fill(LinearGradient(colors: [tint.opacity(0.35), Mist.teal.opacity(0.25)],
                                               startPoint: .top, endPoint: .bottom))
            LiquidFill(level: working ? 0.62 : 0.42, active: working, tint: tint)
                .clipShape(DropletShape())
            DropletShape().stroke(Color.white.opacity(0.45), lineWidth: 1.2)
            Ellipse()
                .fill(Color.white.opacity(0.55))
                .frame(width: 12, height: 22)
                .rotationEffect(.degrees(24))
                .blur(radius: 1.5)
                .offset(x: -16, y: 6)
        }
        .frame(width: 84, height: 110)
        .scaleEffect(breathe)
        .shadow(color: tint.opacity(0.6), radius: 24)
    }
}

/// Radar sweep shown while scanning for nearby A3 units over Bluetooth.
struct RadarScan: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = PhaseClock()

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || !active)) { timeline in
            let sweep = clock.advance(timeline.date.timeIntervalSinceReferenceDate, speed: 1.8)
            ZStack {
                ForEach(1..<4, id: \.self) { ring in
                    Circle().stroke(Mist.aqua.opacity(0.18), lineWidth: 1)
                        .scaleEffect(CGFloat(ring) / 3)
                }
                if active {
                    Circle()
                        .fill(AngularGradient(colors: [Mist.aqua.opacity(0), Mist.aqua.opacity(0.5)],
                                              center: .center, startAngle: .degrees(0), endAngle: .degrees(90)))
                        .rotationEffect(.radians(sweep))
                        .mask(Circle())
                }
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(active ? Mist.aqua : Mist.tertiary)
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
    }
}

/// Animated check mark drawn on success.
struct SuccessCheck: View {
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle().fill(Mist.mint.opacity(0.18))
            Path { path in
                path.move(to: CGPoint(x: 15, y: 29))
                path.addLine(to: CGPoint(x: 24, y: 38))
                path.addLine(to: CGPoint(x: 41, y: 19))
            }
            .trim(from: 0, to: drawn ? 1 : 0)
            .stroke(Mist.mint, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 56, height: 56)
        .scaleEffect(drawn ? 1 : 0.6)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) { drawn = true } }
        .accessibilityHidden(true)
    }
}
