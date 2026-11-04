import XCTest

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testProjectsEditorInspectorAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--agentdevkit-profile", UUID().uuidString]
        app.launch()
        defer { app.terminate() }

        openStarterInspector(app)
        let name = app.textFields["field.node.name"]
        XCTAssertTrue(name.isHittable)
        XCTAssertEqual(name.value as? String, "Overview")
        name.click()
        name.typeKey(.rightArrow, modifierFlags: .command)
        name.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(name.value as? String, "Overvie")
        let save = app.buttons["button.inspector.save"]
        XCTAssertTrue(save.isHittable)
        save.click()
        XCTAssertTrue(app.staticTexts["Overvie"].exists)

        app.terminate()
        app.launch()
        openStarterInspector(app)
        XCTAssertEqual(app.textFields["field.node.name"].value as? String, "Overvie")
    }

    @MainActor
    func testSettingsAppearancePath() {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        openAppearance(app)
        XCTAssertFalse(app.buttons["settings.theme.save"].isEnabled)
    }

    @MainActor
    func testCreateProjectAndEditDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["--agentdevkit-profile", UUID().uuidString]
        app.launch()
        defer { app.terminate() }

        app.buttons["nav.projects.list"].click()
        let add = app.buttons["project.new"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.click()
        let name = app.textFields["project.form.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let save = app.buttons["project.form.save"]
        XCTAssertFalse(save.isEnabled)
        name.click()
        name.typeKey("7", modifierFlags: [])
        XCTAssertTrue(save.isEnabled)
        save.click()

        let title = app.staticTexts["screen.editor"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["7"].exists)
        app.buttons["project.details"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        name.typeKey(.rightArrow, modifierFlags: .command)
        name.typeKey("8", modifierFlags: [])
        save.click()
        XCTAssertTrue(app.staticTexts["78"].waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        app.buttons["nav.projects.list"].click()
        XCTAssertTrue(app.buttons["78"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAppearancePreviewResetAndSaveAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--agentdevkit-profile", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        openAppearance(app)

        let dirty = app.staticTexts["settings.appearance.dirty"]
        let theme = app.popUpButtons["settings.theme"]
        theme.click()
        app.menuItems["Dark"].click()
        XCTAssertTrue(dirty.waitForExistence(timeout: 3))
        app.buttons["settings.appearance.reset"].click()
        XCTAssertFalse(dirty.exists)
        XCTAssertEqual(theme.value as? String, "System")

        let accent = app.popUpButtons["settings.accent"]
        accent.click()
        app.menuItems["Purple"].click()
        theme.click()
        app.menuItems["Dark"].click()
        XCTAssertTrue(app.buttons["settings.theme.save"].isEnabled)
        app.buttons["settings.theme.save"].click()
        XCTAssertFalse(dirty.exists)

        app.terminate()
        app.launch()
        openAppearance(app)
        XCTAssertEqual(app.popUpButtons["settings.accent"].value as? String, "Purple")
        XCTAssertEqual(app.popUpButtons["settings.theme"].value as? String, "Dark")
        XCTAssertFalse(app.buttons["settings.theme.save"].isEnabled)
    }

    @MainActor
    private func openAppearance(_ app: XCUIApplication) {
        app.buttons["nav.settings"].click()
        let advanced = app.buttons["settings.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 3))
        advanced.click()
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.click()
        XCTAssertTrue(app.staticTexts["screen.settings.advanced.appearance"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testRetriesFailedDocument() {
        let app = XCUIApplication()
        app.launchArguments = ["--agentdevkit-fixture", "network-error-v1"]
        app.launch()
        defer { app.terminate() }

        app.buttons["nav.projects.list"].click()
        let recovery = app.buttons["project.open.fixture:network-error"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 3))
        recovery.click()
        let retry = app.buttons["document.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(retry.isHittable)
        retry.click()
        XCTAssertTrue(app.staticTexts["screen.editor"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["node.open.node-1"].isHittable)
    }

    @MainActor
    func testInspectorLongTitleRegression() {
        let app = XCUIApplication()
        let fixture = ["--agentdevkit-fixture", "long-node-names-v1"]
        app.launchArguments = fixture + ["--agentdevkit-legacy-overflow"]
        app.launch()
        defer { app.terminate() }
        openInspector(app, projectId: "fixture:long-node-names", nodeId: "node-1")
        let legacy = inspectorTitle(in: app, evidence: "inspector-legacy")

        app.terminate()
        app.launchArguments = fixture
        app.launch()
        openInspector(app, projectId: "fixture:long-node-names", nodeId: "node-1")
        let fixed = inspectorTitle(in: app, evidence: "inspector-fixed")

        XCTAssertGreaterThan(fixed.titleHeight, legacy.titleHeight * 1.5)
        XCTAssertEqual(fixed.windowWidth, legacy.windowWidth, accuracy: 1)
    }

    @MainActor
    func testMeasureInspectorUserPath() {
        let app = XCUIApplication()
        app.launchArguments = ["--agentdevkit-fixture", "long-node-names-v1"]
        app.launch()
        defer { app.terminate() }
        let home = app.staticTexts.matching(identifier: "screen.home").firstMatch
        var samples: [Double] = []
        for index in 0..<3 {
            if index > 0 { app.buttons["nav.home"].click() }
            XCTAssertTrue(home.exists || home.waitForExistence(timeout: 3))
            let start = ProcessInfo.processInfo.systemUptime
            openInspector(app, projectId: "fixture:long-node-names", nodeId: "node-1")
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            samples.append(elapsed * 1_000)
            XCTAssertTrue(app.buttons["button.inspector.save"].isHittable)
        }
        let attachment = XCTAttachment(string: "uiSamplesMs=\(samples); actionsPerRun=3; screenshotCount=0")
        attachment.name = "inspector-ui-timing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func inspectorTitle(in app: XCUIApplication, evidence: String) -> (titleHeight: CGFloat, windowWidth: CGFloat) {
        let title = app.staticTexts["inspector.node-title"]
        let window = app.windows["main"]
        XCTAssertTrue(title.isHittable)
        XCTAssertEqual(
            app.textFields["field.node.name"].value as? String,
            "Quarterly planning and architecture review with extended notes for accessibility and visual inspection"
        )
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = evidence
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let geometry = XCTAttachment(string: "titleHeight=\(title.frame.height); windowSize=\(window.frame.size)")
        geometry.name = evidence + "-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        return (title.frame.height, window.frame.width)
    }

    @MainActor
    private func openStarterInspector(_ app: XCUIApplication) {
        openInspector(app, projectId: "starter", nodeId: "overview")
    }

    @MainActor
    private func openInspector(_ app: XCUIApplication, projectId: String, nodeId: String) {
        let projects = app.buttons["nav.projects.list"]
        XCTAssertTrue(projects.exists || projects.waitForExistence(timeout: 3))
        projects.click()
        let project = app.buttons["project.open.\(projectId)"]
        XCTAssertTrue(project.exists || project.waitForExistence(timeout: 3))
        project.click()
        let node = app.buttons["node.open.\(nodeId)"]
        XCTAssertTrue(node.exists || node.waitForExistence(timeout: 3))
        node.click()
        let inspector = app.staticTexts["screen.editor.inspector"]
        XCTAssertTrue(inspector.exists || inspector.waitForExistence(timeout: 3))
    }
}
