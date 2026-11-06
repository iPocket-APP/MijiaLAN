import XCTest

final class TVBridgeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.buttons["overview.manageBridge"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testInitialFocusAndBridgeLifecycle() throws {
        let app = launch(["--design-preview"])
        let manage = app.buttons["overview.manageBridge"]
        XCTAssertTrue(manage.hasFocus, "The primary bridge action must be focused on launch")
        capture("overview-design")
        XCUIRemote.shared.press(.select)
        let toggle = app.buttons["bridge.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["家庭桥接未开启"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["家庭桥接已开启"].waitForExistence(timeout: 5))
        capture("bridge-design")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        XCTAssertTrue(manage.hasFocus)
        // The browser's sample-data preview stays in the app at its root.
        XCUIRemote.shared.press(.menu)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(manage.hasFocus)
    }

    @MainActor func testRemoteOpensDeviceAndChangesPower() throws {
        let app = launch(["--design-preview"])
        XCUIRemote.shared.press(.right)
        let lamp = app.buttons["overview.device.preview-lamp"]
        for _ in 0..<5 {
            if lamp.hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(lamp.hasFocus, "The device column must be reachable with the remote")
        XCUIRemote.shared.press(.select)
        let power = app.buttons["device.power"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        XCTAssertTrue(power.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(power.wait(for: \.label, toEqual: "开启设备", timeout: 5))
        capture("device-control-design")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(lamp.waitForExistence(timeout: 5))
        XCTAssertTrue(lamp.label.contains("已关闭"))
    }

    @MainActor func testLiveFixturePowerAndStop() throws {
        let app = launch(["--simulator-fixture"])
        XCTAssertTrue(app.staticTexts["overview.status"].wait(for: \.label, toEqual: "前台桥接已开启", timeout: 15))
        XCUIRemote.shared.press(.right)
        let purifier = app.buttons["overview.device.77"]
        for _ in 0..<4 {
            if purifier.hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(purifier.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        let power = app.buttons["device.power"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        XCTAssertTrue(power.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(power.wait(for: \.label, toEqual: "关闭设备", timeout: 8))
        capture("device-control-live-fixture")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(power.wait(for: \.exists, toEqual: false, timeout: 5))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(app.buttons["overview.manageBridge"].wait(for: \.hasFocus, toEqual: true, timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["bridge.toggle"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["家庭桥接未开启"].waitForExistence(timeout: 8))
    }

    @MainActor func testAllDevicesAndOfflineFilter() throws {
        let app = launch(["--design-preview"])
        XCUIRemote.shared.press(.right)
        let all = app.buttons["overview.allDevices"]
        for _ in 0..<5 {
            if all.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(all.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["devices.title"].waitForExistence(timeout: 5))
        let offline = app.buttons["devices.filter.离线"]
        for _ in 0..<6 {
            if offline.hasFocus { break }
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(offline.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["devices.item.preview-kettle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["devices.item.preview-purifier"].exists)
        capture("devices-offline-filter")
    }

    @MainActor func testSettingsConfigurationAndCancel() throws {
        let app = launch([])
        XCUIRemote.shared.press(.left)
        let settings = app.buttons["navigation.settings"]
        for _ in 0..<5 {
            if settings.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(settings.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["settings.title"].waitForExistence(timeout: 5))
        capture("settings-live")
        XCUIRemote.shared.press(.right)
        let configure = app.buttons["settings.configure"]
        for _ in 0..<6 {
            if configure.hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(configure.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["configuration.host"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["configuration.save"].isEnabled)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["settings.title"].waitForExistence(timeout: 5))
    }

    @MainActor private func openDiagnostics(in app: XCUIApplication) {
        XCUIRemote.shared.press(.left)
        let settings = app.buttons["navigation.settings"]
        for _ in 0..<5 {
            if settings.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(settings.hasFocus)
        XCUIRemote.shared.press(.select)
        let entry = app.buttons["settings.diagnostics"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        for _ in 0..<8 {
            if entry.hasFocus { break }
            let current = app.buttons.allElementsBoundByIndex.first { $0.hasFocus }
            XCUIRemote.shared.press((current?.frame.midY ?? 0) > entry.frame.midY ? .up : .down)
        }
        XCTAssertTrue(entry.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["diagnostics.generate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["diagnostics.generate"].hasFocus)
    }

    @MainActor func testDiagnosticsLiveFixtureReportAndDetails() throws {
        let app = launch(["--simulator-fixture"])
        XCTAssertTrue(app.staticTexts["overview.status"].wait(for: \.label, toEqual: "前台桥接已开启", timeout: 15))
        openDiagnostics(in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["diagnostics.result"].wait(for: \.label, toEqual: "诊断报告已生成，可在本机预览下载。", timeout: 20))
        XCTAssertEqual(app.staticTexts["diagnostics.source"].label, "运行时采集 · 模拟设备")
        capture("diagnostics-live-summary")
        XCUIRemote.shared.press(.right)
        let device = app.buttons["diagnostics.device.77"]
        XCTAssertTrue(device.wait(for: \.hasFocus, toEqual: true, timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["diagnostics.title"].wait(for: \.label, toEqual: "实验净化器", timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "diagnostics.reading.")).firstMatch.waitForExistence(timeout: 5))
        capture("diagnostics-live-device")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["diagnostics.generate"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["settings.title"].waitForExistence(timeout: 5))
    }

    @MainActor func testDiagnosticsPreviewIsExplicitlySampleData() throws {
        let app = launch(["--design-preview"])
        openDiagnostics(in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["diagnostics.result"].wait(for: \.label, toEqual: "示例报告已生成；没有发起设备通信。", timeout: 5))
        XCTAssertEqual(app.staticTexts["diagnostics.source"].label, "示例报告 · 未发起设备通信")
        XCTAssertTrue(app.buttons["diagnostics.device.preview-lamp"].exists)
        capture("diagnostics-preview-summary")
    }

    @MainActor func testUpdateCheckPreviewAndMenuReturn() throws {
        let app = launch(["--design-preview"])
        openDiagnostics(in: app)
        XCUIRemote.shared.press(.menu)
        let entry = app.buttons["settings.updates"]
        for _ in 0..<5 {
            if entry.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(entry.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        let check = app.buttons["updates.check"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        XCTAssertTrue(check.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["updates.status"].wait(for: \.label, toEqual: "发现新版本 0.1.1", timeout: 5))
        XCTAssertTrue(app.staticTexts["示例数据 · 未发起网络请求"].exists)
        capture("updates-preview")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["settings.title"].waitForExistence(timeout: 5))
    }

    @MainActor func testUpdateCheckUsesActualLocalServer() throws {
        let app = launch(["--simulator-fixture", "--update-feed-test", "http://127.0.0.1:3203/tvos/releases.json"])
        openDiagnostics(in: app)
        XCUIRemote.shared.press(.menu)
        let entry = app.buttons["settings.updates"]
        for _ in 0..<5 {
            if entry.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(entry.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["updates.check"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["updates.status"].wait(for: \.label, toEqual: "发现新版本 0.1.1", timeout: 25))
        XCTAssertTrue(app.images["发行说明二维码"].exists)
        capture("updates-http-service")
    }

    @MainActor func testUpdateCheckUsesDeployedTVService() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIJIALAN_LIVE_UPDATE_TEST"] == "1",
                          "Opt in only after the production TV feed has been deployed")
        let app = launch([])
        openDiagnostics(in: app)
        XCUIRemote.shared.press(.menu)
        let entry = app.buttons["settings.updates"]
        for _ in 0..<5 {
            if entry.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(entry.hasFocus)
        XCUIRemote.shared.press(.select)
        let check = app.buttons["updates.check"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        XCTAssertTrue(check.wait(for: \.isEnabled, toEqual: true, timeout: 30))
        for _ in 0..<4 {
            if check.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(check.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["updates.source"].wait(for: \.label, toEqual: "TV 更新服务", timeout: 30))
        XCTAssertTrue(app.staticTexts["updates.status"].wait(for: \.label, toEqual: "暂未发现可用的 TV 安装包", timeout: 5))
        XCTAssertFalse(app.images["发行说明二维码"].exists)
        capture("updates-production-service")
    }
}
