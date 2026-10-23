import SwiftUI

// MARK: - Power

struct PowerOrb: View {
    var isOn: Bool
    var isBusy: Bool
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || (!isOn && !isBusy))) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(Mist.accentGradient) : AnyShapeStyle(Color.white.opacity(0.08)))
                        .scaleEffect(isOn && !reduceMotion ? 1 + 0.025 * sin(t * 2.2) : 1)
                    Circle().strokeBorder(Color.white.opacity(isOn ? 0.45 : 0.16), lineWidth: 1)
                    Image(systemName: "power")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(isOn ? Mist.ink : Color.white)
                    if isBusy {
                        Circle()
                            .trim(from: 0, to: 0.26)
                            .stroke(Mist.aqua, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .padding(-7)
                            .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
                    }
                }
            }
            .frame(width: 74, height: 74)
            .shadow(color: Mist.aqua.opacity(isOn ? 0.6 : 0), radius: 22)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isOn)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isOn ? "关机" : "开机")
    }
}

// MARK: - Mode

struct ModeSelector: View {
    var selection: Int?
    var pending: Int?
    var onSelect: (Int) -> Void
    @Namespace private var namespace
    @Environment(\.isEnabled) private var isEnabled

    static let modes: [(tag: Int, title: String, icon: String)] = [
        (0, "手动", "hand.raised.fill"), (1, "自动", "sparkles"), (2, "睡眠", "moon.zzz.fill"),
        (4, "清洁", "bubbles.and.sparkles.fill")
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.modes, id: \.tag) { mode in
                let selected = selection == mode.tag
                Button {
                    guard !selected else { return }
                    Haptics.tick()
                    onSelect(mode.tag)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.icon).font(.system(size: 18, weight: .semibold))
                            .scaleEffect(selected ? 1.12 : 1)
                        Text(mode.title).font(Mist.rounded(13, .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(selected ? Mist.ink : Mist.secondary)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Mist.accentGradient)
                                .shimmer(pending == mode.tag)
                                .shadow(color: Mist.aqua.opacity(0.5), radius: 12)
                                .matchedGeometryEffect(id: "mode-pill", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white.opacity(0.06)))
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.spring(response: 0.42, dampingFraction: 0.76), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作模式")
    }
}

// MARK: - Fan

/// Capsule slider whose fill "flows" faster with higher fan speed.
struct FanFlowSlider: View {
    @Binding var value: Double                  // 0…100
    /// Speed the device is actually running at (drives the blade spin).
    var runningSpeed: Double
    var onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false
    @State private var lastTick = -1
    @State private var flowClock = PhaseClock()
    @State private var bladeClock = PhaseClock()

    private let height: CGFloat = 58

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = value / 100
            let travel = width - height
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let flow = flowClock.advance(time, speed: 0.3 + fraction * 1.8)
                    let blades = bladeClock.advance(time, speed: runningSpeed * 900)
                    ZStack(alignment: .leading) {
                        ZStack {
                            LinearGradient(colors: [Mist.teal, Mist.aqua, Mist.mint], startPoint: .leading, endPoint: .trailing)
                            FlowStripes(phase: flow).blendMode(.overlay)
                        }
                        .frame(width: height + travel * fraction)
                        .clipShape(Capsule())
                        .shadow(color: Mist.aqua.opacity(isEnabled ? 0.45 : 0), radius: 14)
                        thumb(rotation: blades)
                            .offset(x: travel * fraction)
                    }
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let raw = (gesture.location.x - height / 2) / max(travel, 1)
                        value = (min(max(raw, 0), 1) * 100).rounded()
                        let tick = Int(value) / 5
                        if tick != lastTick { lastTick = tick; Haptics.tick() }
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        dragging = false
                        Haptics.tap()
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: height)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(dragging ? .interactiveSpring(response: 0.18, dampingFraction: 0.86) : .spring(response: 0.6, dampingFraction: 0.8), value: value)
        .accessibilityElement()
        .accessibilityLabel("手动风量")
        .accessibilityValue("\(Int(value))%")
        .accessibilityAdjustableAction { direction in
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(value + 10, 100)
            case .decrement: value = max(value - 10, 0)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }

    private func thumb(rotation: Double) -> some View {
        ZStack {
            Circle().fill(Color.white)
            Image(systemName: "fanblades.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Mist.teal)
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: height - 10, height: height - 10)
        .padding(5)
        .scaleEffect(dragging ? 1.08 : 1)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct FlowStripes: View {
    var phase: Double

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            let offset = CGFloat(phase.truncatingRemainder(dividingBy: 1)) * spacing * 2
            var x = -size.height - spacing * 2 + offset
            while x < size.width + spacing {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                stripe.addLine(to: CGPoint(x: x + size.height + spacing * 0.6, y: 0))
                stripe.addLine(to: CGPoint(x: x + spacing * 0.6, y: size.height))
                stripe.closeSubpath()
                context.fill(stripe, with: .color(.white.opacity(0.22)))
                x += spacing * 2
            }
        }
    }
}

// MARK: - Tiles, toasts, sections

struct StatTile: View {
    var icon: String
    var title: String
    var value: String
    var tint: Color
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(Mist.rounded(22, .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: value)
                Text(title).font(Mist.rounded(12, .medium)).foregroundStyle(Mist.secondary)
            }
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(tint).frame(width: geo.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 5)
                .animation(.spring(response: 0.8, dampingFraction: 0.8), value: progress)
            }
        }
        .glassCard(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

struct FeedbackToast: Identifiable, Equatable {
    enum Kind { case success, warning }
    let id = UUID()
    var kind: Kind
    var text: String
}

struct FeedbackToastView: View {
    var toast: FeedbackToast

    var body: some View {
        let tint = toast.kind == .success ? Mist.mint : Mist.amber
        HStack(spacing: 10) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
            Text(toast.text).font(Mist.rounded(15, .semibold)).foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
        .shadow(color: tint.opacity(0.35), radius: 18, y: 6)
        .accessibilityElement(children: .combine)
    }
}

struct ExpandableSection<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                Haptics.tick()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).foregroundStyle(Mist.aqua).frame(width: 24)
                    Text(title).font(Mist.rounded(16, .semibold)).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Mist.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
            }
        }
        .clipped()
    }
}

/// Labelled row used for "navigate to" actions inside cards.
struct CardLinkLabel: View {
    var title: String
    var icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Mist.aqua).frame(width: 24)
            Text(title).font(Mist.rounded(16, .semibold)).foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Mist.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Target humidity

/// Bar-graph dial for the target humidity. Drag across the bars or use the
/// ± buttons; the change is committed once the finger lifts / taps settle.
struct TargetHumidityControl: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var pending: Bool
    var onCommit: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var dragging = false
    @State private var commitTask: Task<Void, Never>?

    private let barCount = 26

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                stepButton("minus", delta: -1)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(value)")
                        .font(Mist.rounded(52, .bold))
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
                    Text("%").font(Mist.rounded(20, .semibold)).foregroundStyle(Mist.secondary)
                }
                .foregroundStyle(.white)
                .scaleEffect(dragging ? 1.1 : 1)
                .shimmer(pending)
                .animation(.spring(response: 0.35, dampingFraction: 0.62), value: dragging)
                Spacer(minLength: 0)
                stepButton("plus", delta: 1)
            }
            bars
            HStack {
                Text("\(range.lowerBound)%")
                Spacer()
                Text(comfortText).foregroundStyle(Mist.amber)
                    .id(comfortText)
                    .transition(.opacity)
                Spacer()
                Text("\(range.upperBound)%")
            }
            .font(Mist.rounded(11, .semibold))
            .foregroundStyle(Mist.tertiary)
            .animation(.easeInOut(duration: 0.25), value: comfortText)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityLabel("目标湿度")
        .accessibilityValue("\(value)%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private var comfortText: String {
        switch value {
        case ..<40: return "偏干"
        case 40..<46: return "清爽"
        case 46..<61: return "舒适"
        case 61..<71: return "湿润"
        default: return "偏湿"
        }
    }

    private var fraction: Double {
        Double(value - range.lowerBound) / Double(max(range.upperBound - range.lowerBound, 1))
    }

    private var bars: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let position = Double(index) / Double(barCount - 1)
                    let lit = position <= fraction + 0.0001
                    Capsule()
                        .fill(lit ? AnyShapeStyle(LinearGradient(colors: [Mist.amber, Mist.coral.opacity(0.85)],
                                                                 startPoint: .bottom, endPoint: .top))
                                  : AnyShapeStyle(Color.white.opacity(0.10)))
                        .frame(height: 14 + 30 * position)
                        .scaleEffect(x: 1, y: lit && dragging ? 1.08 : 1, anchor: .bottom)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7).delay(Double(index) * 0.006), value: lit)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !dragging { dragging = true; commitTask?.cancel() }
                        let raw = min(max(gesture.location.x / max(geo.size.width, 1), 0), 1)
                        let next = range.lowerBound + Int((raw * Double(range.upperBound - range.lowerBound)).rounded())
                        if next != value { value = next; Haptics.tick() }
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        dragging = false
                        Haptics.tap()
                        onCommit()
                    }
            )
        }
        .frame(height: 46)
    }

    private func stepButton(_ icon: String, delta: Int) -> some View {
        Button { step(delta) } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white.opacity(0.09)))
                .overlay(Circle().strokeBorder(Mist.hairline, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(delta < 0 ? value <= range.lowerBound : value >= range.upperBound)
        .accessibilityLabel(delta < 0 ? "降低目标湿度" : "提高目标湿度")
    }

    /// Repeated taps are coalesced into one command 0.8 s after the last one.
    private func step(_ delta: Int) {
        let next = min(max(value + delta, range.lowerBound), range.upperBound)
        guard next != value else { return }
        Haptics.tick()
        value = next
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            onCommit()
        }
    }
}

// MARK: - Feature switches

struct FeatureSwitchTile: View {
    var icon: String
    var title: String
    var detail: String
    var isOn: Bool
    var pending: Bool
    var tint: Color
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isOn ? Mist.ink : tint)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.16))))
                        .shadow(color: tint.opacity(isOn ? 0.6 : 0), radius: 10)
                        .scaleEffect(isOn ? 1.06 : 1)
                    Spacer()
                    switchKnob
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Mist.rounded(15, .bold)).foregroundStyle(.white)
                    Text(pending ? "等待设备确认…" : detail)
                        .font(Mist.rounded(11, .medium))
                        .foregroundStyle(pending ? Mist.aqua : Mist.tertiary)
                        .lineLimit(1)
                        .id(pending)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isOn ? tint.opacity(0.16) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(isOn ? tint.opacity(0.55) : Mist.hairline, lineWidth: 1)
            )
            .shimmer(pending)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: isOn)
        .animation(.easeInOut(duration: 0.25), value: pending)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var switchKnob: some View {
        Capsule()
            .fill(isOn ? tint : Color.white.opacity(0.14))
            .frame(width: 40, height: 24)
            .overlay(
                Circle().fill(Color.white).frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: isOn ? 8 : -8)
            )
    }
}
