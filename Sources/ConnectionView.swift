import SwiftUI

struct ConnectionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = A3ConnectionCoordinator.shared.session
    @StateObject private var coordinator = A3ConnectionCoordinator.shared
    @StateObject private var bluetooth = A3Bluetooth()
    @State private var hotspotName = ""
    @State private var hotspotPassword = ""
    @State private var didAutostart = false
    @State private var fan = 0.0
    @State private var editingFan = false
    @State private var controlNavigationID = UUID()
    /// Optimistic mode highlight until the device confirms (or rejects) it.
    @State private var pendingMode: Int?
    /// Which control is waiting for device confirmation ("lock", "hThreshold", …).
    @State private var pendingField: String?
    @State private var targetDraft = 50
    @State private var editingTarget = false
    /// Bumped on every device-confirmed change; drives the gauge ripple.
    @State private var applyPulse = 0
    @State private var toast: FeedbackToast?
    @Namespace private var coreNamespace
    @AppStorage(SimedgeConnectionBridge.enabledKey) private var simedgeConnectionEnabled = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                MistBackground(mood: mood, intensity: mistIntensity)
                ScrollView {
                    VStack(spacing: 18) {
                        header.entrance(0)
                        if session.report.isEmpty {
                            heroCard
                                .entrance(1)
                                .transition(.asymmetric(insertion: .opacity,
                                                        removal: .scale(scale: 0.9).combined(with: .opacity)))
                        } else {
                            dashboard
                                .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                                        removal: .opacity))
                            connectionCard.entrance(4)
                        }
                        simedgeCard.entrance(5)
                        diagnosticsCard.entrance(6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .animation(.spring(response: 0.65, dampingFraction: 0.84), value: session.report.isEmpty)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: session.canControl)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: waterShortage)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await MainActor.run { if session.canRequestStatus { session.requestStatus() } }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                if let toast {
                    FeedbackToastView(toast: toast)
                        .padding(.horizontal, 24)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .tint(Mist.aqua)
        .id(controlNavigationID)
        .onReceive(NotificationCenter.default.publisher(for: SimedgeConnectionBridge.showControlNotification)) { _ in
            controlNavigationID = UUID()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                session.enteredBackground()
                SimedgeConnectionBridge.shared.enteredBackground()
            }
            if phase == .active {
                session.becameActive()
                SimedgeConnectionBridge.shared.becameActive()
            }
        }
        .onOpenURL { url in
            if !SimedgeConnectionBridge.shared.handle(url) { coordinator.handleCallback(url) }
        }
        .onChange(of: simedgeConnectionEnabled) { enabled in
            SimedgeConnectionBridge.shared.preferenceChanged(enabled: enabled)
        }
        .onChange(of: bluetooth.status) { status in
            // Observe value transitions, not a publisher recreated by body updates.
            // @Published replays its current value on each new subscription;
            // logging that value publishes session.events and can loop on iOS 17.
            session.recordBluetooth(status: status)
        }
        .onChange(of: session.report["cadr"]) { value in
            if !editingFan, let value, (0...100).contains(value) { fan = Double(value) }
        }
        .onChange(of: session.report["mode"]) { mode in
            if mode == pendingMode { pendingMode = nil }
        }
        .onChange(of: session.targetHumidity) { value in
            if !editingTarget, pendingField != "hThreshold", let value { targetDraft = clampTarget(value) }
        }
        .onChange(of: session.isSendingControl) { sending in
            guard !sending else { return }
            pendingMode = nil
            let wasTarget = pendingField == "hThreshold"
            pendingField = nil
            editingTarget = false
            if wasTarget, let value = session.targetHumidity { targetDraft = clampTarget(value) }
            let message = session.commandStatus
            if message.hasPrefix("加湿器已确认") || message.hasPrefix("实机开关") {
                applyPulse += 1
                Haptics.success()
                showToast(.success, "已生效")
            } else if !message.isEmpty {
                Haptics.warning()
                showToast(.warning, message)
            }
        }
        .onAppear {
            if let value = session.targetHumidity { targetDraft = clampTarget(value) }
            guard !didAutostart else { return }
            didAutostart = true
            session.recordBluetooth(status: bluetooth.status)
            if ProcessInfo.processInfo.arguments.contains("--run-passive-ble-scan") {
                bluetooth.startPassiveScanDiagnostic()
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--run-self-check") {
                _ = ProtocolChecks.run()
            }
            if ProcessInfo.processInfo.arguments.contains("--run-connection-checks") {
                Task { await ConnectionChecks.run() }
            }
            if ProcessInfo.processInfo.arguments.contains("--run-local-server") {
                session.start(duration: 600)
            }
        }
    }

    // MARK: - Derived state

    private var isConnecting: Bool { session.isRunning || session.isStarting || coordinator.isInvokingShortcut }
    private var isPowerOn: Bool { session.report["power"] == 1 }
    private var waterShortage: Bool { session.report["mode"] == 5 }

    private var mood: MistMood {
        if waterShortage { return .alert }
        if session.canControl { return isPowerOn ? .running : .standby }
        return isConnecting ? .connecting : .idle
    }

    private var runningFanSpeed: Double {
        guard session.canControl, isPowerOn else { return 0 }
        if session.report["mode"] == 0, let cadr = session.report["cadr"], (0...100).contains(cadr) {
            return Double(cadr) / 100
        }
        return 0.6
    }

    private var mistIntensity: Double {
        if session.canControl { return isPowerOn ? 0.3 + 0.7 * runningFanSpeed : 0.1 }
        return isConnecting ? 0.4 : 0.15
    }

    private var bodyHumidity: Double? {
        session.report["h0"].flatMap { (0...10000).contains($0) ? Double($0) / 100 : nil }
    }

    private var sensorHumidity: Double? {
        guard session.report["gooseOnline"] == 1 else { return nil }
        return session.report["h"].flatMap { (0...10000).contains($0) ? Double($0) / 100 : nil }
    }

    private var targetHumidity: Int? { session.targetHumidity }

    private func clampTarget(_ value: Int) -> Int {
        min(max(value, A3LocalSession.targetHumidityRange.lowerBound), A3LocalSession.targetHumidityRange.upperBound)
    }

    private var temperature: Double? {
        for key in ["t", "t0"] {
            if let raw = session.report[key], raw > 0, raw < 99999 { return Double(raw) / 100 }
        }
        return nil
    }

    private var waterLevel: Int? { session.report["water"].flatMap { (0...110).contains($0) ? min($0, 100) : nil } }

    private var modeName: String {
        switch session.report["mode"] {
        case 0: return "手动模式"
        case 1: return "自动模式"
        case 2: return "睡眠模式"
        case 5: return "缺水保护"
        default: return "模式未知"
        }
    }

    private var headerText: String {
        if session.canControl {
            if waterShortage { return "A3 已连接 · 缺水保护" }
            return isPowerOn ? "A3 已连接 · 运行中" : "A3 已连接 · 待机"
        }
        if !session.report.isEmpty { return "正在核对设备状态" }
        return isConnecting ? "正在建立本地连接" : "未连接"
    }

    private var statusText: String {
        coordinator.isInvokingShortcut && session.isRunning ? "请保持此页面打开，等待加湿器接入。" : session.status
    }

    private func showToast(_ kind: FeedbackToast.Kind, _ text: String) {
        let next = FeedbackToast(kind: kind, text: text)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { toast = next }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toast?.id == next.id {
                withAnimation(.easeInOut(duration: 0.35)) { toast = nil }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("秒新加湿器")
                    .font(Mist.rounded(32, .bold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    StatusDot(color: Mist.accent(mood), pulsing: session.canControl || isConnecting)
                    Text(headerText)
                        .font(Mist.rounded(14, .medium))
                        .foregroundStyle(Mist.secondary)
                        .id(headerText)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .animation(.easeInOut(duration: 0.35), value: headerText)
            }
            Spacer()
            Image(systemName: "drop.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Mist.ink)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Mist.accentGradient))
                .shadow(color: Mist.aqua.opacity(0.5), radius: 14)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    // MARK: - Not connected: hero

    private var heroCard: some View {
        VStack(spacing: 18) {
            ConnectOrb(working: isConnecting, tint: Mist.accent(mood))
                .matchedGeometryEffect(id: "core", in: coreNamespace)
            VStack(spacing: 8) {
                Text(isConnecting ? "正在连接 A3" : "连接你的 A3")
                    .font(Mist.rounded(24, .bold))
                    .foregroundStyle(.white)
                    .id(isConnecting)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                Text("点一次连接，自动准备手机热点并接入已配网的 A3。")
                    .font(Mist.rounded(15))
                    .foregroundStyle(Mist.secondary)
                    .multilineTextAlignment(.center)
            }
            .animation(.easeInOut(duration: 0.35), value: isConnecting)
            connectionControls
        }
        .frame(maxWidth: .infinity)
        .glassCard(padding: 22)
    }

    // MARK: - Connected: dashboard

    private var dashboard: some View {
        VStack(spacing: 18) {
            gaugeCard.entrance(1)
            if waterShortage {
                waterAlert.transition(.move(edge: .top).combined(with: .opacity))
            }
            operationCard.entrance(2)
            targetCard.entrance(3)
            featuresCard.entrance(3)
            statsGrid.entrance(3)
        }
    }

    private var gaugeCard: some View {
        VStack(spacing: 20) {
            // While dragging the target control, preview the new marker on the dial.
            HumidityGauge(humidity: bodyHumidity, target: editingTarget || pendingField == "hThreshold" ? targetDraft : targetHumidity,
                          active: isPowerOn && session.canControl, caption: "机身湿度", applyPulse: applyPulse)
                .matchedGeometryEffect(id: "core", in: coreNamespace)
                .padding(.top, 4)
            HStack(spacing: 16) {
                PowerOrb(isOn: isPowerOn, isBusy: session.isSendingControl) {
                    session.setPower(!isPowerOn)
                }
                .disabled(!session.canControl || session.isSendingControl)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.canControl ? (isPowerOn ? "正在加湿" : "已关机") : "等待控制通道")
                        .font(Mist.rounded(21, .bold))
                        .foregroundStyle(.white)
                        .id("\(session.canControl)-\(isPowerOn)")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    Text(modeName)
                        .font(Mist.rounded(14, .medium))
                        .foregroundStyle(Mist.secondary)
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isPowerOn)
                Spacer(minLength: 0)
            }
            if !session.commandStatus.isEmpty {
                Text(session.commandStatus)
                    .font(Mist.rounded(12, .medium))
                    .foregroundStyle(Mist.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(session.commandStatus)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.commandStatus)
        .glassCard(padding: 20)
    }

    private var waterAlert: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Mist.amber)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Mist.amber.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text("缺水保护").font(Mist.rounded(17, .bold)).foregroundStyle(.white)
                Text("设备提示水量不足，当前处于缺水保护。")
                    .font(Mist.rounded(13)).foregroundStyle(Mist.secondary)
            }
        }
        .glassCard(padding: 16, tint: Mist.amber)
        .accessibilityElement(children: .combine)
    }

    private var operationCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            cardTitle("运行模式", icon: "slider.horizontal.3")
            ModeSelector(selection: pendingMode ?? session.report["mode"], pending: pendingMode) { mode in
                guard session.canAdjustOperation else { return }
                pendingMode = mode
                session.setMode(mode)
                if !session.isSendingControl { pendingMode = nil }
            }
            .disabled(!session.canAdjustOperation)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    cardTitle("手动风量", icon: "wind")
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(fan))")
                            .font(Mist.rounded(30, .bold))
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: fan)
                        Text("%").font(Mist.rounded(15, .semibold)).foregroundStyle(Mist.secondary)
                    }
                    .foregroundStyle(.white)
                    .scaleEffect(editingFan ? 1.12 : 1, anchor: .trailing)
                    .animation(.spring(response: 0.35, dampingFraction: 0.65), value: editingFan)
                }
                FanFlowSlider(value: $fan, runningSpeed: runningFanSpeed) { editing in
                    editingFan = editing
                    guard !editing, session.canAdjustOperation else { return }
                    if session.report["mode"] != 0 { pendingMode = 0 }
                    session.setFan(Int(fan))
                    if !session.isSendingControl { pendingMode = nil }
                }
                .disabled(!session.canAdjustOperation)
            }
            Text(waterShortage ? "加水并恢复正常后，可调节模式和风量。" : "调节风量会切换到手动模式。")
                .font(Mist.rounded(12, .medium))
                .foregroundStyle(Mist.tertiary)
        }
        .glassCard()
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                cardTitle("目标湿度", icon: "scope")
                Spacer()
                Text("实验")
                    .font(Mist.rounded(11, .bold))
                    .foregroundStyle(Mist.amber)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Mist.amber.opacity(0.15)))
            }
            TargetHumidityControl(value: Binding(
                get: { targetDraft },
                set: { targetDraft = $0; editingTarget = true }
            ), range: A3LocalSession.targetHumidityRange, pending: pendingField == "hThreshold") {
                guard session.canControl, !session.isSendingControl else { return }
                guard targetDraft != targetHumidity else { editingTarget = false; return }
                pendingField = "hThreshold"
                session.setTargetHumidity(targetDraft)
                if !session.isSendingControl { pendingField = nil; editingTarget = false }
            }
            .disabled(!session.canControl || (session.isSendingControl && pendingField != "hThreshold"))
            Text("自动模式下机器会按目标湿度调节。")
                .font(Mist.rounded(12, .medium))
                .foregroundStyle(Mist.tertiary)
        }
        .glassCard(tint: Mist.amber)
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("功能开关", icon: "switch.2")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                featureTile("lock", icon: "lock.fill", title: "童锁", on: "机身按键已锁定", off: "机身按键可用", tint: Mist.violet)
                featureTile("anion", icon: "sparkle", title: "负离子", on: "负离子已开启", off: "负离子已关闭", tint: Mist.mint)
            }
        }
        .glassCard()
    }

    private func featureTile(_ field: String, icon: String, title: String, on: String, off: String, tint: Color) -> some View {
        let isOn = session.report[field] == 1
        return FeatureSwitchTile(icon: icon, title: title, detail: isOn ? on : off, isOn: isOn,
                                 pending: pendingField == field, tint: tint) {
            guard session.canControl, !session.isSendingControl else { return }
            pendingField = field
            session.setSwitch(field, enabled: !isOn)
            if !session.isSendingControl { pendingField = nil }
        }
        .disabled(!session.canControl || session.report[field] == nil
                  || (session.isSendingControl && pendingField != field))
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            StatTile(icon: "drop.fill", title: "机身湿度",
                     value: bodyHumidity.map { String(format: "%.1f%%", $0) } ?? "--",
                     tint: Mist.aqua, progress: bodyHumidity.map { $0 / 100 })
            StatTile(icon: "scope", title: "目标湿度",
                     value: targetHumidity.map { "\($0)%" } ?? "--",
                     tint: Mist.amber, progress: targetHumidity.map { Double($0) / 100 })
            if let sensorHumidity {
                StatTile(icon: "antenna.radiowaves.left.and.right", title: "外置传感器湿度",
                         value: String(format: "%.1f%%", sensorHumidity), tint: Mist.violet,
                         progress: sensorHumidity / 100)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            StatTile(icon: "wind", title: "当前风量",
                     value: session.report["cadr"].map { "\($0)%" } ?? "--",
                     tint: Mist.mint, progress: session.report["cadr"].map { Double($0) / 100 })
            if let temperature {
                StatTile(icon: "thermometer.medium", title: "温度",
                         value: String(format: "%.1f°C", temperature), tint: Mist.coral,
                         progress: min(max(temperature / 40, 0), 1))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if let waterLevel {
                StatTile(icon: "waterbottle.fill", title: "水箱水量",
                         value: "\(waterLevel)%", tint: waterLevel < 20 ? Mist.amber : Mist.aqua,
                         progress: Double(waterLevel) / 100)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: sensorHumidity != nil)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: temperature != nil)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: waterLevel != nil)
    }

    // MARK: - Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("手机连接", icon: "personalhotspot")
            connectionControls
        }
        .glassCard()
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !session.canControl {
                Button {
                    Haptics.tap()
                    coordinator.runShortcut()
                } label: {
                    Label("一键连接 A3", systemImage: "bolt.fill")
                }
                .buttonStyle(MistButtonStyle())
                .shimmer(!isConnecting)
                .accessibilityIdentifier("one-tap-connect")
                .disabled(session.isStarting || coordinator.isInvokingShortcut)
                Text("首次使用需添加「连接 A3」快捷指令，并完成下方配网。")
                    .font(Mist.rounded(12, .medium)).foregroundStyle(Mist.tertiary)
                if let shortcutURL = Bundle.main.url(forResource: "连接 A3", withExtension: "shortcut") {
                    ShareLink(item: shortcutURL) {
                        Label("添加「连接 A3」快捷指令", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(MistButtonStyle(kind: .secondary))
                }
            }
            if !coordinator.shortcutMessage.isEmpty {
                Text(coordinator.shortcutMessage)
                    .font(Mist.rounded(13, .medium)).foregroundStyle(.white)
            }
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if isConnecting && !session.canControl {
                        ProgressView().tint(Mist.aqua).scaleEffect(0.8)
                    } else {
                        Image(systemName: session.canControl ? "checkmark.seal.fill" : "info.circle")
                            .foregroundStyle(session.canControl ? Mist.mint : Mist.tertiary)
                    }
                }
                .frame(width: 20, height: 18)
                Text(statusText)
                    .font(Mist.rounded(13, .medium))
                    .foregroundStyle(Mist.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(statusText)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityIdentifier("connection-status")
            }
            .animation(.easeInOut(duration: 0.3), value: statusText)
            if isConnecting {
                Text("控制时保持 App 在前台。本轮最长 10 分钟，结束后关闭热点。热点只连接 A3。")
                    .font(Mist.rounded(12, .medium)).foregroundStyle(Mist.tertiary)
                Button(role: .destructive) {
                    Haptics.tap()
                    bluetooth.disconnect()
                    coordinator.cancelConnection()
                } label: {
                    Label("结束本轮连接", systemImage: "stop.fill")
                }
                .buttonStyle(MistButtonStyle(kind: .destructive))
            } else {
                ExpandableSection(title: "手动连接", icon: "hand.tap") {
                    Text("关闭个人热点后点下方按钮，等服务就绪，再开启热点并返回。首次使用请在系统设置开启“最大兼容性”。")
                        .font(Mist.rounded(13)).foregroundStyle(Mist.secondary)
                    Button { session.start() } label: {
                        Label("准备本地服务", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(MistButtonStyle(kind: .secondary))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("manual-connection")
            }
            Rectangle().fill(Mist.hairline).frame(height: 1)
            NavigationLink {
                ProvisioningView(session: session, bluetooth: bluetooth,
                                 hotspotName: $hotspotName, hotspotPassword: $hotspotPassword)
            } label: {
                CardLinkLabel(title: "首次配网或更换手机热点", icon: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-provisioning")
        }
    }

    // MARK: - Simedge & diagnostics

    private var simedgeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("Simedge 快捷连接", icon: "bolt.horizontal.circle.fill")
            Toggle("允许 Simedge 一键连接", isOn: $simedgeConnectionEnabled)
                .font(Mist.rounded(16, .semibold))
                .foregroundStyle(.white)
                .tint(Mist.aqua)
            Text("首次完成下方蓝牙配网后，在 Simedge 快捷工具中添加“连接秒新 A3”。它会先关闭热点、等待本地服务就绪，再开启热点并等待 A3 接入，无需苹果快捷指令。")
                .font(Mist.rounded(12, .medium)).foregroundStyle(Mist.tertiary)
            Text("后台时间不足时会提前打开本 App 继续连接；控制期间请保持 App 在前台。连接只建立通道，不会自动启动加湿。")
                .font(Mist.rounded(12, .medium)).foregroundStyle(Mist.tertiary)
        }
        .glassCard()
    }

    private var diagnosticsCard: some View {
        ExpandableSection(title: "连接诊断", icon: "waveform.path.ecg") {
            Group {
                Text("设备消息连接数：\(session.connectedClients)")
                if let type = session.registeredType { Text("设备型号代码：\(type)") }
                Text("已收到设置字段：\(session.settingsReport.count)")
            }
            .font(Mist.rounded(14, .medium))
            .foregroundStyle(Mist.secondary)
            if session.canRequestStatus {
                Button("读取当前设备状态") { session.requestStatus() }
                    .buttonStyle(MistButtonStyle(kind: .secondary))
            }
            if !session.events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.events.enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Mist.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.25)))
            }
            NavigationLink { ProbeView() } label: {
                CardLinkLabel(title: "研发端口检查", icon: "stethoscope")
            }
            .buttonStyle(.plain)
            .disabled(session.isRunning)
            .opacity(session.isRunning ? 0.4 : 1)
        }
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-diagnostics")
    }

    private func cardTitle(_ title: String, icon: String) -> some View {
        Label {
            Text(title).font(Mist.rounded(15, .semibold)).foregroundStyle(.white)
        } icon: {
            Image(systemName: icon).foregroundStyle(Mist.aqua)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Provisioning

struct ProvisioningView: View {
    @ObservedObject var session: A3LocalSession
    @ObservedObject var bluetooth: A3Bluetooth
    @Binding var hotspotName: String
    @Binding var hotspotPassword: String
    @FocusState private var focusedField: Field?

    private enum Field { case name, password }

    private var provisioned: Bool { bluetooth.state == .provisioned }

    var body: some View {
        ZStack {
            MistBackground(mood: provisioned ? .running : .connecting, intensity: 0.3)
            ScrollView {
                VStack(spacing: 16) {
                    introCard.entrance(0)
                    StepCard(number: 1, title: "选择加湿器", done: bluetooth.canProvision || provisioned) {
                        scanSection
                    }
                    .entrance(1)
                    StepCard(number: 2, title: "连接手机热点", done: provisioned) {
                        credentialSection
                    }
                    .entrance(2)
                    if provisioned {
                        HStack(spacing: 14) {
                            SuccessCheck()
                            Text(bluetooth.status)
                                .font(Mist.rounded(15, .semibold)).foregroundStyle(.white)
                        }
                        .glassCard(tint: Mist.mint)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.55, dampingFraction: 0.82), value: provisioned)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("首次配网")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("只需设置一次。以后热点名称和密码不变，就不必重复配网。")
                .font(Mist.rounded(15, .medium)).foregroundStyle(.white)
            if !session.isRunning {
                Label("请先返回首页开始连接，再开启个人热点。", systemImage: "exclamationmark.circle.fill")
                    .font(Mist.rounded(13, .semibold))
                    .foregroundStyle(Mist.amber)
            }
        }
        .glassCard(tint: session.isRunning ? .clear : Mist.amber)
    }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                RadarScan(active: bluetooth.state == .scanning)
                VStack(alignment: .leading, spacing: 10) {
                    Text(bluetooth.status)
                        .font(Mist.rounded(13, .medium)).foregroundStyle(Mist.secondary)
                        .id(bluetooth.status)
                        .transition(.opacity)
                    Button {
                        Haptics.tap()
                        bluetooth.scan()
                    } label: {
                        Label("查找附近的 A3", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(MistButtonStyle(kind: .secondary))
                    .disabled(!session.isRunning)
                }
                .animation(.easeInOut(duration: 0.3), value: bluetooth.status)
            }
            ForEach(bluetooth.devices) { device in
                Button {
                    Haptics.tap()
                    bluetooth.connect(to: device)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "drop.circle.fill").font(.system(size: 24)).foregroundStyle(Mist.aqua)
                        Text(device.name).font(Mist.rounded(16, .semibold)).foregroundStyle(.white)
                        Spacer()
                        SignalBars(rssi: device.rssi)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!session.isRunning)
                .accessibilityLabel(device.name)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: bluetooth.devices)
    }

    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputField(icon: "personalhotspot", focused: focusedField == .name) {
                TextField("个人热点名称（iPhone 名称）", text: $hotspotName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .name)
            }
            inputField(icon: "key.fill", focused: focusedField == .password) {
                SecureField("个人热点的 Wi-Fi 密码", text: $hotspotPassword)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
            }
            Text("凭据只通过蓝牙发送给选中的 A3；发送后清空密码。加湿器会改连此热点。")
                .font(Mist.rounded(12, .medium)).foregroundStyle(Mist.tertiary)
            Button {
                Haptics.tap()
                focusedField = nil
                bluetooth.provision(ssid: hotspotName, password: hotspotPassword)
                hotspotPassword = ""
            } label: {
                Label("让 A3 连接这个热点", systemImage: "paperplane.fill")
            }
            .buttonStyle(MistButtonStyle())
            .disabled(!session.isRunning || !bluetooth.canProvision || hotspotName.isEmpty || hotspotPassword.isEmpty)
        }
    }

    private func inputField<Input: View>(icon: String, focused: Bool, @ViewBuilder field: () -> Input) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(focused ? Mist.aqua : Mist.tertiary).frame(width: 22)
            field().font(Mist.rounded(16)).foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(focused ? Mist.aqua.opacity(0.8) : Mist.hairline, lineWidth: focused ? 1.5 : 1))
        .shadow(color: Mist.aqua.opacity(focused ? 0.3 : 0), radius: 10)
        .animation(.easeInOut(duration: 0.25), value: focused)
    }
}

private struct StepCard<Content: View>: View {
    var number: Int
    var title: String
    var done: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(done ? AnyShapeStyle(Mist.accentGradient) : AnyShapeStyle(Color.white.opacity(0.10)))
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Mist.ink)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text("\(number)").font(Mist.rounded(15, .bold)).foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 32, height: 32)
                .shadow(color: Mist.aqua.opacity(done ? 0.5 : 0), radius: 10)
                Text(title).font(Mist.rounded(18, .bold)).foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.65), value: done)
            content()
        }
        .glassCard()
    }
}

private struct SignalBars: View {
    var rssi: Int

    private var level: Int { rssi > -60 ? 3 : (rssi > -80 ? 2 : 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...3, id: \.self) { bar in
                Capsule()
                    .fill(bar <= level ? Mist.mint : Color.white.opacity(0.18))
                    .frame(width: 4, height: CGFloat(4 + bar * 4))
            }
        }
        .accessibilityHidden(true)
    }
}
