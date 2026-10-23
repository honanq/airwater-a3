import XCTest

final class HomeInteractionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeDisclosuresRespondToTaps() throws {
        let app = XCUIApplication()
        app.launch()
        let connect = app.buttons["one-tap-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        XCTAssertTrue(connect.isEnabled)
        XCTAssertTrue(connect.isHittable)

        let manual = app.buttons["手动连接"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        manual.tap()
        XCTAssertTrue(app.buttons["准备本地服务"].waitForExistence(timeout: 5))
        manual.tap()
        XCTAssertFalse(app.buttons["准备本地服务"].exists)

        let diagnostics = app.buttons["连接诊断"]
        if !diagnostics.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        XCTAssertTrue(app.staticTexts["设备消息连接数：0"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "home-disclosures-responsive"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Never press prepare/scan/control: no listeners, BLE, or real A3 commands.
    }

    @MainActor
    func testProvisioningNavigationAndTextInput() throws {
        let app = XCUIApplication()
        app.launch()
        let provisioning = app.buttons["open-provisioning"]
        XCTAssertTrue(provisioning.waitForExistence(timeout: 15))
        provisioning.tap()
        XCTAssertTrue(app.navigationBars["首次配网"].waitForExistence(timeout: 5))

        let name = app.textFields["个人热点名称（iPhone 名称）"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("UI-Test-Hotspot")
        XCTAssertEqual(name.value as? String, "UI-Test-Hotspot")
        XCTAssertFalse(app.buttons["查找附近的 A3"].isEnabled)
        app.navigationBars["首次配网"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["one-tap-connect"].waitForExistence(timeout: 5))
    }
}
