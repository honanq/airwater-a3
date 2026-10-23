import Combine
import XCTest
@testable import AirwaterProbe

final class InteractionRegressionTests: XCTestCase {
    @MainActor
    func testRepeatedSubscriptionsDoNotPublishOrWriteDuplicateEvents() async {
        let session = A3LocalSession()
        let bluetooth = A3Bluetooth()
        let initialCount = session.events.count
        var publications = 0
        let observation = session.$events.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }

        // Simulate SwiftUI recreating the old body-local publisher. Each fresh
        // removeDuplicates subscription replays "未连接"; the model must be safe.
        for _ in 0..<1_000 {
            let subscription = bluetooth.$status.removeDuplicates().sink {
                session.recordBluetooth(status: $0)
            }
            subscription.cancel()
        }

        XCTAssertEqual(session.events.count, initialCount + 1)
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.isStarting)
    }

    @MainActor
    func testRealBluetoothTransitionsArePreserved() async {
        let session = A3LocalSession()
        let initialCount = session.events.count
        for status in ["未连接", "未连接", "正在扫描", "正在扫描", "未连接"] {
            session.recordBluetooth(status: status)
        }
        XCTAssertEqual(session.events.count, initialCount + 3)
        XCTAssertTrue(session.events.last?.hasSuffix("蓝牙：未连接") == true)
    }

    @MainActor
    func testOtherEventsDoNotResetBluetoothDeduplication() async {
        let session = A3LocalSession()
        session.recordBluetooth(status: "未连接")
        session.stop(reason: "离线回归检查")
        let events = session.events
        session.recordBluetooth(status: "未连接")
        XCTAssertEqual(session.events, events)
    }

    @MainActor
    func testExistingOfflineProtocolChecks() async {
        let result = ProtocolChecks.run()
        XCTAssertEqual(result["failed"] as? Int, 0, "\(result)")
    }
}
