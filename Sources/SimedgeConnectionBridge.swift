import Darwin
import Foundation
import UIKit

/// Bounded, credential-free handoff to Simedge's SpringBoard quick tool.
/// Darwin notification names are correlation, not authentication: the user must
/// explicitly enable this bridge; it never accepts arbitrary commands or URLs.
@MainActor
final class SimedgeConnectionBridge {
    static let shared = SimedgeConnectionBridge()
    static let enabledKey = "simedgeConnectionEnabled"
    static let showControlNotification = Notification.Name("SimedgeShowA3Control")
    private let requestName = "com.honanq.airwater.simedge.v1.request"
    private var requestObserver: Int32 = -1
    private var observers: [Int32] = []
    private var request: UInt64?
    private var lastFinishedRequest: UInt64?
    private var lastFailure: UInt64 = 0
    private var stage = "idle"
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var connectionToken: String?
    private init() {}

    func start() {
        guard requestObserver == -1 else { return }
        let result = notify_register_dispatch(requestName, &requestObserver, .main) { [weak self] token in
            var value: UInt64 = 0
            guard notify_get_state(token, &value) == NOTIFY_STATUS_OK else { return }
            Task { @MainActor in self?.accept(value) }
        }
        guard result == NOTIFY_STATUS_OK else { requestObserver = -1; return }
        var pending: UInt64 = 0
        if notify_get_state(requestObserver, &pending) == NOTIFY_STATUS_OK { accept(pending) }
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "a3local", url.host == "simedge" else { return false }
        // Showing the app must not restart or modify a completed connection.
        if url.path == "/show" {
            NotificationCenter.default.post(name: Self.showControlNotification, object: nil)
            return true
        }
        guard url.path == "/connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "request" })?.value,
              raw.count == 16, raw.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt64(raw, radix: 16) else { return true }
        // A URL alone cannot command hotspot changes. It must match the live
        // request that Simedge published before launching this app.
        var pending: UInt64 = 0
        guard requestObserver != -1,
              notify_get_state(requestObserver, &pending) == NOTIFY_STATUS_OK,
              pending == value else { return true }
        accept(value)
        return true
    }

    func preferenceChanged(enabled: Bool) {
        if !enabled, let request { fail(request, code: 1) }
    }

    private func base(_ request: UInt64) -> String {
        String(format: "com.honanq.airwater.simedge.v1.%016llx", request)
    }

    private func post(_ event: String, for request: UInt64, state: UInt64 = 0) {
        let name = base(request) + "." + event
        var token: Int32 = -1
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return }
        notify_set_state(token, state)
        notify_post(name)
        notify_cancel(token)
    }

    private func observe(_ event: String, for request: UInt64) -> Bool {
        var token: Int32 = -1
        let result = notify_register_dispatch(base(request) + "." + event, &token, .main) { [weak self] _ in
            Task { @MainActor in self?.receive(event, for: request) }
        }
        guard result == NOTIFY_STATUS_OK else { return false }
        observers.append(token)
        return true
    }

    private func accept(_ value: UInt64) {
        let timestamp = TimeInterval(value >> 32)
        let age = Date().timeIntervalSince1970 - timestamp
        guard value != 0, age >= -5, age <= 120 else { return }
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            post("failed", for: value, state: 1)
            return
        }
        if lastFinishedRequest == value {
            post(lastFailure == 0 ? "connected" : "failed", for: value, state: lastFailure)
            return
        }
        if request == value {
            post("accepted", for: value)
            if stage == "waiting-hotspot" { post("ready", for: value) }
            return
        }
        let coordinator = A3ConnectionCoordinator.shared
        if coordinator.session.canControl {
            NotificationCenter.default.post(name: Self.showControlNotification, object: nil)
            post("connected", for: value)
            return
        }
        // Never tear down a manually started or unrelated Shortcuts connection.
        guard request == nil, !coordinator.session.isStarting,
              !coordinator.session.isRunning, !coordinator.isInvokingShortcut else {
            post("failed", for: value, state: 2)
            return
        }
        request = value
        stage = "waiting-off"
        for event in ["hotspot-off", "hotspot-on", "hotspot-error", "cancel"] {
            guard observe(event, for: value) else { fail(value, code: 6); return }
        }
        if UIApplication.shared.applicationState != .active {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Simedge A3 connection") { [weak self] in
                Task { @MainActor in
                    guard let self, self.request == value else { return }
                    self.fail(value, code: 7)
                }
            }
        }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 110_000_000_000) } catch { return }
            guard let self, self.request == value else { return }
            self.fail(value, code: 4)
        }
        post("accepted", for: value)
    }

    private func receive(_ event: String, for value: UInt64) {
        guard request == value else { return }
        switch event {
        case "cancel": fail(value, code: 5)
        case "hotspot-error": fail(value, code: 8)
        case "hotspot-off":
            guard stage == "waiting-off" else { return }
            let coordinator = A3ConnectionCoordinator.shared
            guard !coordinator.session.isStarting, !coordinator.session.isRunning,
                  !coordinator.isInvokingShortcut else { fail(value, code: 2); return }
            coordinator.adoptExternalRun()
            stage = "preparing"
            let runID = UUID()
            connectionToken = runID.uuidString
            task = Task { @MainActor [weak self] in
                do {
                    let token = try await coordinator.prepare(runID: runID)
                    guard let self, self.request == value, !Task.isCancelled else { return }
                    self.connectionToken = token
                    self.stage = "waiting-hotspot"
                    self.post("ready", for: value)
                } catch {
                    guard let self, self.request == value else { return }
                    self.fail(value, code: 3)
                }
            }
        case "hotspot-on":
            guard stage == "waiting-hotspot", let token = connectionToken else { return }
            stage = "waiting-device"
            task = Task { @MainActor [weak self] in
                do {
                    try await A3ConnectionCoordinator.shared.finish(connectionToken: token, timeout: 85)
                    guard let self, self.request == value, !Task.isCancelled,
                          A3ConnectionCoordinator.shared.session.canControl else { return }
                    self.lastFinishedRequest = value
                    self.lastFailure = 0
                    NotificationCenter.default.post(name: Self.showControlNotification, object: nil)
                    self.post("connected", for: value)
                    self.cleanup()
                } catch {
                    guard let self, self.request == value else { return }
                    self.fail(value, code: 4)
                }
            }
        default: break
        }
    }

    func enteredBackground() {
        guard let value = request, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Simedge A3 connection") { [weak self] in
            Task { @MainActor in
                guard let self, self.request == value else { return }
                self.fail(value, code: 7)
            }
        }
    }

    func becameActive() {
        endBackgroundTask()
        var pending: UInt64 = 0
        if requestObserver != -1, notify_get_state(requestObserver, &pending) == NOTIFY_STATUS_OK {
            accept(pending)
        }
    }

    private func fail(_ value: UInt64, code: UInt64) {
        guard request == value else { return }
        task?.cancel()
        if let token = connectionToken { A3ConnectionCoordinator.shared.cancelConnection(ifToken: token) }
        lastFinishedRequest = value
        lastFailure = code
        post("failed", for: value, state: code)
        cleanup()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func cleanup() {
        timeout?.cancel()
        timeout = nil
        task = nil
        for observer in observers { notify_cancel(observer) }
        observers.removeAll()
        request = nil
        connectionToken = nil
        stage = "idle"
        endBackgroundTask()
    }
}
