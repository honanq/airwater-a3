import SwiftUI
import UIKit

// Visual language: "night mist" — deep water backdrop, drifting light, glass
// cards and a single aqua→mint accent that warms to amber on warnings.

enum MistMood: Int, CaseIterable {
    case idle, connecting, running, standby, alert
}

enum Mist {
    static let ink = Color(red: 0.03, green: 0.07, blue: 0.11)
    static let aqua = Color(red: 0.36, green: 0.88, blue: 0.95)
    static let teal = Color(red: 0.11, green: 0.60, blue: 0.72)
    static let mint = Color(red: 0.52, green: 0.97, blue: 0.78)
    static let violet = Color(red: 0.53, green: 0.50, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.36)
    static let coral = Color(red: 1.0, green: 0.46, blue: 0.48)
    static let secondary = Color.white.opacity(0.64)
    static let tertiary = Color.white.opacity(0.40)
    static let hairline = Color.white.opacity(0.12)

    static let accentGradient = LinearGradient(colors: [aqua, mint], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func accent(_ mood: MistMood) -> Color {
        switch mood {
        case .idle: return violet
        case .connecting: return aqua
        case .running: return mint
        case .standby: return teal
        case .alert: return amber
        }
    }

    static func backdrop(_ mood: MistMood) -> [Color] {
        switch mood {
        case .idle: return [Color(red: 0.07, green: 0.07, blue: 0.17), Color(red: 0.03, green: 0.04, blue: 0.09)]
        case .connecting: return [Color(red: 0.03, green: 0.12, blue: 0.20), Color(red: 0.02, green: 0.04, blue: 0.09)]
        case .running: return [Color(red: 0.02, green: 0.17, blue: 0.20), Color(red: 0.01, green: 0.05, blue: 0.08)]
        case .standby: return [Color(red: 0.06, green: 0.10, blue: 0.14), Color(red: 0.02, green: 0.03, blue: 0.06)]
        case .alert: return [Color(red: 0.20, green: 0.11, blue: 0.05), Color(red: 0.05, green: 0.03, blue: 0.04)]
        }
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Integrates time × speed so a speed change never makes an animation jump.
final class PhaseClock {
    private var last: Double?
    private(set) var value = 0.0

    func advance(_ time: Double, speed: Double) -> Double {
        if let last { value += min(max(time - last, 0), 0.1) * speed }
        last = time
        return value
    }
}

@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Backdrop

struct MistBackground: View {
    var mood: MistMood
    /// 0…1: how much mist is "flowing" (power and fan speed).
    var intensity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = PhaseClock()

    var body: some View {
        ZStack {
            ForEach(MistMood.allCases, id: \.self) { candidate in
                LinearGradient(colors: Mist.backdrop(candidate), startPoint: .top, endPoint: .bottom)
                    .opacity(candidate == mood ? 1 : 0)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                let t = clock.advance(timeline.date.timeIntervalSinceReferenceDate, speed: 0.6 + intensity * 1.4)
                Canvas { context, size in
                    Self.drawGlow(in: &context, size: size, time: t, color: Mist.accent(mood))
                    Self.drawMist(in: &context, size: size, time: t, intensity: intensity)
                }
                // Rasterize on the GPU in one pass instead of compositing each shape.
                .drawingGroup()
            }
            .id(mood)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 1.2), value: mood)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static func drawGlow(in context: inout GraphicsContext, size: CGSize, time t: Double, color: Color) {
        let blobs: [(x: Double, y: Double, r: Double, s: Double, o: Double)] = [
            (0.15, 0.10, 0.70, 0.31, 0.40), (0.92, 0.38, 0.55, 0.23, 0.26), (0.35, 0.92, 0.80, 0.17, 0.22)
        ]
        for (i, blob) in blobs.enumerated() {
            let center = CGPoint(x: size.width * (blob.x + 0.10 * sin(t * blob.s + Double(i))),
                                 y: size.height * (blob.y + 0.05 * cos(t * blob.s * 1.3 + Double(i) * 2)))
            let radius = max(size.width, size.height) * blob.r * 0.6
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [color.opacity(blob.o), color.opacity(0)]),
                center: center, startRadius: 0, endRadius: radius))
        }
    }

    private static func drawMist(in context: inout GraphicsContext, size: CGSize, time t: Double, intensity: Double) {
        // Soft radial particles instead of a full-screen blur filter, which
        // was re-run every frame and dropped frames while scrolling.
        for i in 0..<34 {
            let seed = Double(i)
            let a = Self.fract(sin(seed * 12.9898) * 43758.5453)
            let b = Self.fract(sin(seed * 78.233) * 12345.678)
            let progress = Self.fract(t * (0.018 + 0.03 * b) + a)
            let x = size.width * a + sin(t * 0.7 + seed) * 16
            let y = size.height * (1.08 - progress * 1.25)
            let radius = 7 + 26 * b
            let alpha = sin(progress * .pi) * (0.05 + 0.16 * intensity)
            let soft = radius * 1.8
            let center = CGPoint(x: x, y: y)
            context.fill(Path(ellipseIn: CGRect(x: x - soft, y: y - soft, width: soft * 2, height: soft * 2)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(alpha), .white.opacity(0)]),
                                               center: center, startRadius: 0, endRadius: soft))
        }
    }

    private static func fract(_ value: Double) -> Double { value - floor(value) }
}

// MARK: - Surfaces

struct GlassCard: ViewModifier {
    var padding: CGFloat = 20
    var tint: Color = .clear

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // A live material re-blurs the animated backdrop on every
                // frame of a scroll; a static translucent fill looks the same
                // over a dark gradient at a fraction of the GPU cost.
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.11), Color.white.opacity(0.045)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(tint.opacity(0.10)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.03)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
            )
    }
}

/// Staggered rise-in for cards on first appearance.
struct Entrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 30)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97)
            .onAppear {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(Double(index) * 0.07)) { shown = true }
            }
    }
}

struct Shimmer: ViewModifier {
    var active = true
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.38), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width * 1.5)
                }
                .mask(content)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(false)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) { phase = 1.5 }
            }
    }
}

extension View {
    func glassCard(padding: CGFloat = 20, tint: Color = .clear) -> some View {
        modifier(GlassCard(padding: padding, tint: tint))
    }
    func entrance(_ index: Int) -> some View { modifier(Entrance(index: index)) }
    func shimmer(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}

// MARK: - Buttons

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct MistButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Mist.rounded(17, .semibold))
            .foregroundStyle(kind == .primary ? Mist.ink : (kind == .destructive ? Mist.coral : .white))
            .padding(.vertical, 15)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background(background)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(kind == .primary ? 0.35 : 0.14), lineWidth: 1))
            .shadow(color: Mist.aqua.opacity(kind == .primary && isEnabled ? 0.45 : 0), radius: 18, y: 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: configuration.isPressed)
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary: Mist.accentGradient
        case .secondary: Color.white.opacity(0.09)
        case .destructive: Mist.coral.opacity(0.14)
        }
    }
}

/// Small pulsing status dot.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1.25 : 0.5).opacity(pulse ? 0 : 1)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
        .onAppear { animate() }
        .onChange(of: pulsing) { _ in animate() }
        .accessibilityHidden(true)
    }

    private func animate() {
        pulse = false
        guard pulsing else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
    }
}
