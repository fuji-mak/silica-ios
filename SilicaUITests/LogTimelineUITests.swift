import XCTest

final class LogTimelineUITests: XCTestCase {
    @MainActor
    func testGuidedSetupRequiresSavedPlaceAndResumes() throws {
        continueAfterFailure = false
        for language in ["ja", "en"] {
            let app = XCUIApplication()
            let commonArguments = [
                "--debug-pro", "--debug-permissions-ready",
                "-appLanguage", language,
                "-AppleLanguages", "(\(language))",
                "-AppleLocale", language == "ja" ? "ja_JP" : "en_US",
            ]
            // Use the existing screenshot fixture reset for a fresh first-run database.
            app.launchArguments = commonArguments + [
                "--debug-onboarding-capture",
                "-silica.hasCompletedOnboarding", "false",
                "-silica.resumeInitialSetupAfterSettings", "true",
                "-silica.initialSetupResumePage", "2",
            ]
            app.launch()
            let continueButton = app.buttons[language == "ja" ? "Silicaを始める" : "Start Using Silica"]
            XCTAssertTrue(continueButton.waitForExistence(timeout: 15))
            continueButton.tap()

            let guide = app.staticTexts["guidedSetup.placeGuide"]
            XCTAssertTrue(guide.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["guidedSetup.skipExport"].exists)
            XCTAssertTrue(app.staticTexts["guidedSetup.step1"].exists)
            XCTAssertFalse(app.tabBars.firstMatch.exists, "場所登録中にタブバーが表示されています")

            // No reset or forced stage on relaunch: the stored progress must resume.
            app.terminate()
            app.launchArguments = commonArguments + ["--debug-skip-welcome-onboarding"]
            app.launch()
            XCTAssertTrue(guide.waitForExistence(timeout: 10))
            attachGuidedSetupScreenshot(app, name: "\(language)-01-place-guide")

            let map = app.maps.firstMatch
            XCTAssertTrue(map.waitForExistence(timeout: 5))
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 1.0)
            let name = app.textFields["placeForm.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            let save = app.buttons["placeForm.save"]
            XCTAssertFalse(save.isEnabled, "場所名が空でも登録できます")
            app.buttons[language == "ja" ? "場所を選び直す" : "Choose another place"].tap()
            XCTAssertTrue(guide.waitForExistence(timeout: 5), "キャンセルで登録案内を飛ばしています")
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 1.0)
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            attachGuidedSetupScreenshot(app, name: "\(language)-02-place-form")
            name.tap()
            name.typeText("Home Test")
            XCTAssertTrue(save.isEnabled)
            save.tap()

            let skipExport = app.buttons["guidedSetup.skipExport"]
            XCTAssertTrue(skipExport.waitForExistence(timeout: 10), "登録後に出力設定へ進みません")
            XCTAssertFalse(app.buttons["guidedSetup.finish"].exists, "出力先未設定でも完了できます")
            XCTAssertTrue(app.staticTexts["guidedSetup.step2"].exists)
            XCTAssertFalse(app.tabBars.firstMatch.exists, "出力設定中にタブバーが表示されています")
            attachGuidedSetupScreenshot(app, name: "\(language)-03-export-guide")
            app.terminate()
            app.launch()
            XCTAssertTrue(skipExport.waitForExistence(timeout: 10), "出力設定の途中から再開しません")
            skipExport.tap()
            let completion = app.staticTexts["guidedSetup.completed"]
            XCTAssertTrue(completion.waitForExistence(timeout: 5))
            XCTAssertFalse(app.tabBars.firstMatch.exists)
            // The real map tab is behind the message, but cannot be operated yet.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.94)).tap()
            XCTAssertTrue(completion.exists)
            XCTAssertFalse(app.tabBars.firstMatch.exists)
            attachGuidedSetupScreenshot(app, name: "\(language)-04-completion")
            app.terminate()
            app.launch()
            XCTAssertTrue(completion.waitForExistence(timeout: 10))
            app.buttons["guidedSetup.start"].tap()
            XCTAssertTrue(app.tabBars.buttons[language == "ja" ? "マップ" : "Map"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.tabBars.buttons[language == "ja" ? "マップ" : "Map"].isSelected)
            app.terminate()
            app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(guide.exists)
            XCTAssertFalse(skipExport.exists, "完了後に初期設定が繰り返されます")
            app.tabBars.buttons[language == "ja" ? "場所" : "Places"].tap()
            XCTAssertTrue(app.staticTexts["Home Test"].firstMatch.waitForExistence(timeout: 5))
            app.terminate()

            // Already-saved places satisfy the required step when setup is re-entered.
            app.launchArguments = commonArguments + [
                "-silica.hasCompletedOnboarding", "false",
                "-silica.resumeInitialSetupAfterSettings", "true",
                "-silica.initialSetupResumePage", "2",
            ]
            app.launch()
            XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
            continueButton.tap()
            XCTAssertTrue(skipExport.waitForExistence(timeout: 10))
            XCTAssertFalse(guide.exists)
            skipExport.tap()
            XCTAssertTrue(completion.waitForExistence(timeout: 5))
            app.buttons["guidedSetup.start"].tap()
            app.terminate()
        }
    }

    @MainActor
    private func attachGuidedSetupScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testInitialSetupShowsFeatureWarningWithoutLocationPermission() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-missing-location-permission",
            "-silica.hasCompletedOnboarding",
            "false",
            "-silica.resumeInitialSetupAfterSettings",
            "true",
            "-silica.initialSetupResumePage",
            "2",
            "-appLanguage",
            "ja",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        let warning = app.staticTexts["setup-location-permission-warning"]
        XCTAssertTrue(
            warning.waitForExistence(timeout: 10),
            "必要な位置情報がない場合の機能制限警告が表示されません"
        )
        XCTAssertGreaterThan(warning.frame.width, 250, "機能制限警告の表示幅が不足しています")
        XCTAssertTrue(
            app.frame.contains(warning.frame),
            "機能制限警告が表示領域内に収まっていません"
        )

        let settingsButton = app.buttons["iPhoneの設定を開く"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 2), "設定ボタンが表示されません")
        XCTAssertGreaterThanOrEqual(
            settingsButton.frame.minY,
            warning.frame.maxY,
            "設定ボタンが警告より上に表示されています"
        )
        XCTAssertLessThanOrEqual(
            settingsButton.frame.minY - warning.frame.maxY,
            16,
            "設定ボタンが警告の直下に配置されていません"
        )
        XCTAssertTrue(app.buttons["設定を開く"].exists, "必須権限の設定導線が表示されません")
        XCTAssertFalse(app.buttons["このまま続ける"].exists, "権限なしで初期設定を完了できます")
    }

    @MainActor
    func testInitialSetupRequiresMotionPermission() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-permissions-ready",
            "--debug-missing-motion-permission",
            "-silica.hasCompletedOnboarding",
            "false",
            "-silica.resumeInitialSetupAfterSettings",
            "true",
            "-silica.initialSetupResumePage",
            "2",
            "-appLanguage",
            "ja",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        let warning = app.staticTexts["setup-motion-permission-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "モーション権限の警告が表示されません")
        XCTAssertTrue(app.staticTexts["記録精度が低下中"].exists)
        XCTAssertTrue(app.buttons["設定を開く"].exists)
        XCTAssertFalse(app.buttons["Silicaを始める"].exists, "モーション権限なしで初期設定を完了できます")
    }

    @MainActor
    func testMotionPermissionWarningRemainsAvailableAfterOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-welcome-onboarding",
            "--debug-missing-motion-permission",
            "-silica.hasCompletedOnboarding",
            "true",
            "-silica.guidedSetupStage",
            "complete",
            "-appLanguage",
            "ja",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        let banner = app.buttons["motion-permission-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "通常画面にモーション権限の設定導線が表示されません")
        XCTAssertTrue(app.staticTexts["記録精度が低下中"].exists)
    }

    @MainActor
    func testInitialSetupContinueRespondsAtCapsuleEdge() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-silica.hasCompletedOnboarding",
            "false",
            "-silica.resumeInitialSetupAfterSettings",
            "true",
            "-silica.initialSetupResumePage",
            "0",
            "-appLanguage",
            "ja",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        let continueButton = app.buttons["setup-permission-continue"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 10),
            "位置情報ページの続けるボタンが表示されません"
        )
        XCTAssertGreaterThan(
            continueButton.frame.width,
            250,
            "続けるボタンのタップ領域がカプセル全体に広がっていません"
        )

        continueButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
            .tap()

        let motionPage = app.staticTexts["モーションとフィットネスを許可"]
        let advancedToMotionPage = motionPage.waitForExistence(timeout: 3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let requestedLocationPermission =
            app.alerts.firstMatch.exists || springboard.alerts.firstMatch.exists

        XCTAssertTrue(
            advancedToMotionPage || requestedLocationPermission,
            "続けるボタンの端をタップしても権限要求または次ページへの遷移が起きません"
        )
    }

    @MainActor
    func testCaptureOnboardingTimelineScreenshots() throws {
        let languages: [(code: String, locale: String)] = [
            ("ja", "ja_JP"),
            ("en", "en_US"),
        ]
        let screens: [(name: String, arguments: [String])] = [
            ("log", ["--debug-onboarding-log"]),
            ("history", ["--debug-onboarding-history-data"]),
        ]

        for language in languages {
            for screen in screens {
                let app = XCUIApplication()
                app.launchArguments = [
                    "--debug-skip-welcome-onboarding",
                    "--debug-onboarding-capture",
                    "--debug-pro",
                    "-appLanguage",
                    language.code,
                    "-appAppearance",
                    "light",
                    "-AppleLanguages",
                    "(\(language.code))",
                    "-AppleLocale",
                    language.locale,
                ] + screen.arguments
                app.launch()

                XCTAssertTrue(
                    waitForAnyLabel(["log-screen-title"], in: app, timeout: 10),
                    "\(language.code)-\(screen.name) のログ画面が表示されません"
                )
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.5))

                if screen.name == "history" {
                    for _ in 0..<3 {
                        app.swipeRight()
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.7))
                    }
                    let firstHistoryPlace = language.code == "en"
                        ? app.staticTexts["Shibuya Hikarie"]
                        : app.staticTexts["渋谷ヒカリエ"]
                    XCTAssertTrue(
                        firstHistoryPlace.waitForExistence(timeout: 4),
                        "\(language.code) の過去ログへ移動できません"
                    )
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
                }

                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "onboarding-\(language.code)-\(screen.name)"
                attachment.lifetime = .keepAlways
                add(attachment)

                app.terminate()
            }
        }
    }

    @MainActor
    func testCaptureOnboardingScreenshots() throws {
        let languages: [(code: String, locale: String)] = [
            ("ja", "ja_JP"),
            ("en", "en_US"),
        ]
        let screens: [(name: String, arguments: [String], readinessLabels: [String], delay: TimeInterval)] = [
            (
                "map",
                ["--debug-map", "--debug-map-wide"],
                ["マップ", "Map"],
                10.0
            ),
            (
                "log",
                ["--debug-onboarding-log"],
                ["log-screen-title"],
                2.5
            ),
            (
                "history",
                ["--debug-onboarding-history-data"],
                ["log-screen-title"],
                1.5
            ),
            (
                "export",
                ["--debug-export"],
                ["出力", "Export"],
                2.0
            ),
        ]

        for language in languages {
            for screen in screens {
                let app = XCUIApplication()
                app.launchArguments = [
                    "--debug-skip-welcome-onboarding",
                    "--debug-onboarding-capture",
                    "--debug-pro",
                    "-appLanguage",
                    language.code,
                    "-appAppearance",
                    "light",
                    "-AppleLanguages",
                    "(\(language.code))",
                    "-AppleLocale",
                    language.locale,
                ] + screen.arguments
                app.launch()

                XCTAssertTrue(
                    waitForAnyLabel(screen.readinessLabels, in: app, timeout: 10),
                    "\(language.code)-\(screen.name) の画面が表示されません"
                )

                RunLoop.current.run(until: Date(timeIntervalSinceNow: screen.delay))

                if screen.name == "history" {
                    for _ in 0..<3 {
                        app.swipeRight()
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.7))
                    }
                    let firstHistoryPlace = language.code == "en"
                        ? app.staticTexts["Shibuya Hikarie"]
                        : app.staticTexts["渋谷ヒカリエ"]
                    XCTAssertTrue(
                        firstHistoryPlace.waitForExistence(timeout: 4),
                        "\(language.code) の過去ログへ移動できません"
                    )
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
                }

                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "onboarding-\(language.code)-\(screen.name)"
                attachment.lifetime = .keepAlways
                add(attachment)

                app.terminate()
            }
        }
    }

    @MainActor
    func testCaptureAppStorePlacesScreenshots() throws {
        let languages: [(code: String, locale: String)] = [
            ("ja", "ja_JP"),
            ("en", "en_US"),
        ]

        for language in languages {
            let app = XCUIApplication()
            app.launchArguments = [
                "--debug-skip-welcome-onboarding",
                "--debug-onboarding-capture",
                "--debug-pro",
                "-appLanguage",
                language.code,
                "-appAppearance",
                "light",
                "-AppleLanguages",
                "(\(language.code))",
                "-AppleLocale",
                language.locale,
                "--debug-onboarding-log",
                "--debug-app-store-places",
            ]
            app.launch()

            XCTAssertTrue(
                waitForAnyLabel(["log-screen-title"], in: app, timeout: 10),
                "\(language.code) の撮影用データを読み込めません"
            )

            let placesTab = app.tabBars.buttons[language.code == "en" ? "Places" : "場所"]
            XCTAssertTrue(
                placesTab.waitForExistence(timeout: 5),
                "\(language.code) の場所タブが見つかりません"
            )
            placesTab.tap()

            let firstPlace = app.staticTexts[language.code == "en" ? "Home" : "自宅"]
            XCTAssertTrue(
                firstPlace.waitForExistence(timeout: 5),
                "\(language.code) の登録場所一覧が表示されません"
            )
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "appstore-\(language.code)-places"
            attachment.lifetime = .keepAlways
            add(attachment)

            app.terminate()
        }
    }

    @MainActor
    func testCaptureAppStoreSettingsScreenshots() throws {
        let languages: [(code: String, locale: String)] = [
            ("ja", "ja_JP"),
            ("en", "en_US"),
        ]

        for language in languages {
            let app = XCUIApplication()
            app.launchArguments = [
                "--debug-skip-welcome-onboarding",
                "--debug-onboarding-capture",
                "--debug-pro",
                "--debug-settings",
                "-appLanguage",
                language.code,
                "-appAppearance",
                "light",
                "-AppleLanguages",
                "(\(language.code))",
                "-AppleLocale",
                language.locale,
            ]
            app.launch()

            let settingsTitle = app.staticTexts[language.code == "en" ? "Settings" : "設定"]
            XCTAssertTrue(
                settingsTitle.waitForExistence(timeout: 10),
                "\(language.code) の設定画面が表示されません"
            )
            let proCard = app.buttons["Silica Pro"]
            XCTAssertTrue(
                proCard.waitForExistence(timeout: 15),
                "\(language.code) のProカードを含む設定画面が完成しません"
            )
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "appstore-\(language.code)-settings"
            attachment.lifetime = .keepAlways
            add(attachment)

            app.terminate()
        }
    }

    @MainActor
    func testAutomaticExportNotificationPreferencePersists() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-welcome-onboarding",
            "--debug-pro",
            "--debug-settings",
            "-appLanguage",
            "ja",
            "-appAppearance",
            "light",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        func revealNotificationToggle() -> XCUIElement {
            let toggle = app.switches[
                "settings-automatic-export-notifications-toggle"
            ]
            for _ in 0..<8 where toggle.isHittable == false {
                app.swipeUp()
            }
            return toggle
        }

        var notificationToggle = revealNotificationToggle()
        XCTAssertTrue(
            notificationToggle.isHittable,
            "自動出力の通知設定が設定画面に表示されません"
        )
        XCTAssertTrue(
            notificationToggle.label.contains("出力完了を通知"),
            "自動出力の通知設定が日本語で表示されません"
        )
        XCTAssertTrue(
            app.frame.contains(notificationToggle.frame),
            "自動出力の通知設定が表示領域内に収まっていません"
        )

        let initialValue = String(describing: notificationToggle.value ?? "")
        notificationToggle
            .coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .tap()
        let toggledValueExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", initialValue),
            object: notificationToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [toggledValueExpectation], timeout: 3),
            .completed,
            "自動出力の通知設定を切り替えられません"
        )
        let toggledValue = String(describing: notificationToggle.value ?? "")

        app.terminate()
        app.launch()

        notificationToggle = revealNotificationToggle()
        XCTAssertTrue(
            notificationToggle.isHittable,
            "再起動後に自動出力の通知設定が表示されません"
        )
        XCTAssertEqual(
            String(describing: notificationToggle.value ?? ""),
            toggledValue,
            "自動出力の通知設定が再起動後に保持されません"
        )

        notificationToggle
            .coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .tap()
        let restoredValueExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", initialValue),
            object: notificationToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [restoredValueExpectation], timeout: 3),
            .completed,
            "検証後に自動出力の通知設定を元へ戻せません"
        )
    }

    @MainActor
    private func waitForAnyLabel(
        _ labels: [String],
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            for label in labels {
                let staticText = app.staticTexts[label]
                let navigationBar = app.navigationBars[label]
                let tabButton = app.tabBars.buttons[label]
                if (staticText.exists && staticText.isHittable) ||
                    (navigationBar.exists && navigationBar.isHittable) ||
                    (tabButton.exists && tabButton.isHittable) {
                    return true
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    func testProCardStudioControlsAutoHideAndReveal() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-welcome-onboarding",
            "--debug-settings",
            "--debug-subscription",
            "--debug-pro",
        ]
        app.launch()

        let card = app.buttons["subscription-card-preview"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        let cardReadyExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"),
            object: card
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [cardReadyExpectation], timeout: 8),
            .completed
        )
        card.tap()

        let backgroundButton = app.buttons["card-studio-background"]
        let saveButton = app.buttons["card-studio-save"]
        XCTAssertTrue(backgroundButton.waitForExistence(timeout: 3))
        XCTAssertTrue(saveButton.exists)

        let visibleControlsScreenshot = XCTAttachment(screenshot: app.screenshot())
        visibleControlsScreenshot.name = "Card studio controls"
        visibleControlsScreenshot.lifetime = .keepAlways
        add(visibleControlsScreenshot)

        guard let initialBackground = backgroundButton.value as? String else {
            XCTFail("現在のカード背景名を取得できません")
            return
        }

        var observedBackgrounds: Set<String> = [initialBackground]
        var previousBackground = initialBackground

        for _ in 0..<5 {
            backgroundButton.tap()
            let backgroundChangedExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "value != %@",
                    previousBackground
                ),
                object: backgroundButton
            )
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [backgroundChangedExpectation],
                    timeout: 2
                ),
                .completed,
                "背景ボタンを押しても次の背景へ切り替わりません"
            )
            guard let currentBackground = backgroundButton.value as? String else {
                XCTFail("切替後のカード背景名を取得できません")
                return
            }
            observedBackgrounds.insert(currentBackground)
            previousBackground = currentBackground
        }

        XCTAssertEqual(
            observedBackgrounds.count,
            6,
            "背景ボタンで6種類すべてを順番に選べません"
        )

        backgroundButton.tap()
        let backgroundWrappedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", initialBackground),
            object: backgroundButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [backgroundWrappedExpectation], timeout: 2),
            .completed,
            "最後の背景から最初の背景へ戻りません"
        )

        let changedBackgroundScreenshot = XCTAttachment(screenshot: app.screenshot())
        changedBackgroundScreenshot.name = "Card studio cycled background"
        changedBackgroundScreenshot.lifetime = .keepAlways
        add(changedBackgroundScreenshot)

        saveButton.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let photoPermissionAlert = springboard.alerts.firstMatch
        if photoPermissionAlert.waitForExistence(timeout: 2) {
            let allowButton = ["許可", "Allow"]
                .lazy
                .map { photoPermissionAlert.buttons[$0] }
                .first(where: { $0.exists })
            XCTAssertNotNil(
                allowButton,
                "写真への追加を許可するボタンが見つかりません"
            )
            allowButton?.tap()
        }
        let cardSavedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@ OR value == %@",
                "保存済み",
                "Saved"
            ),
            object: saveButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [cardSavedExpectation], timeout: 6),
            .completed,
            "カード画像を写真へ保存できません"
        )

        let controlsHiddenExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: backgroundButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [controlsHiddenExpectation], timeout: 6),
            .completed,
            "カード操作ボタンが自動で消えません"
        )

        let lowerEdge = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.92)
        )
        let nearbyLowerEdge = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.62, dy: 0.89)
        )
        lowerEdge.press(
            forDuration: 0.12,
            thenDragTo: nearbyLowerEdge
        )

        XCTAssertTrue(
            backgroundButton.waitForExistence(timeout: 2),
            "画面下部をなぞってもカード操作ボタンが再表示されません"
        )
        XCTAssertTrue(saveButton.exists)
    }

    @MainActor
    func testFreeSubscriptionCardPaywallDismissalOpensSubscriptionManagement() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-welcome-onboarding",
            "--debug-settings",
            "--debug-free",
        ]
        app.launch()

        let subscriptionCard = app.buttons["settings-subscription-card"]
        XCTAssertTrue(
            subscriptionCard.waitForExistence(timeout: 8),
            "設定画面にFreeプランのカードが表示されません"
        )
        let cardEnabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"),
            object: subscriptionCard
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [cardEnabledExpectation], timeout: 8),
            .completed,
            "サブスクリプション確認後もFreeプランのカードを操作できません"
        )
        subscriptionCard.tap()

        XCTAssertTrue(
            app.staticTexts["Silica Pro"].waitForExistence(timeout: 6),
            "Freeプランのカードを押してもPaywallが表示されません"
        )

        let continueFreeButton = app.buttons["paywall-continue-free"]
        XCTAssertTrue(
            continueFreeButton.waitForExistence(timeout: 3),
            "Paywallを閉じるための無料プランボタンが表示されません"
        )
        continueFreeButton.tap()

        XCTAssertTrue(
            app.navigationBars["サブスクリプション"].waitForExistence(timeout: 4)
                || app.navigationBars["Subscription"].waitForExistence(timeout: 1),
            "Freeカード起点のPaywallを閉じてもサブスクリプション設定へ遷移しません"
        )
    }

    @MainActor
    func testFreePlanRestrictedHistoryOpensPaywall() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-welcome-onboarding",
            "--debug-free",
            "--debug-history-paywall",
            "-appLanguage",
            "en",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
        ]
        app.launch()

        XCTAssertTrue(
            app.tabBars.buttons["ログ"].waitForExistence(timeout: 6)
                || app.tabBars.buttons["Log"].waitForExistence(timeout: 1)
        )
        app.swipeRight()

        XCTAssertTrue(
            app.staticTexts["Silica Pro"].waitForExistence(timeout: 6),
            "Freeで31日の閲覧範囲より前へ移動してもPaywallが表示されません"
        )
        assertLoadedPaywallPrice(
            app.staticTexts["paywall-price-monthly"],
            planName: "月額"
        )
        assertLoadedPaywallPrice(
            app.staticTexts["paywall-price-annual"],
            planName: "年額"
        )
        assertLoadedPaywallPrice(
            app.staticTexts["paywall-price-lifetime"],
            planName: "買い切り"
        )
    }

    @MainActor
    func testFreePlanFourthSavedPlaceOpensPaywall() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-welcome-onboarding",
            "--debug-log-history",
            "--debug-free",
        ]
        app.launch()

        let placesTab = app.tabBars.buttons["場所"].exists
            ? app.tabBars.buttons["場所"]
            : app.tabBars.buttons["Places"]
        XCTAssertTrue(placesTab.waitForExistence(timeout: 6))
        placesTab.tap()

        let addPlaceButton = app.buttons["場所を追加"].exists
            ? app.buttons["場所を追加"]
            : app.buttons["Add Place"]
        XCTAssertTrue(addPlaceButton.waitForExistence(timeout: 3))
        addPlaceButton.tap()

        XCTAssertTrue(
            app.staticTexts["Silica Pro"].waitForExistence(timeout: 4),
            "Freeで4件目を追加しようとしてもPaywallが表示されません"
        )
    }

    @MainActor
    func testOngoingStayRowOpensDetails() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-welcome-onboarding",
            "--debug-onboarding-capture",
            "--debug-onboarding-log",
            "--debug-ongoing-candidate",
            "--debug-pro",
            "-appLanguage",
            "ja",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        let ongoingStay = app.buttons["ongoing-stay-row"]
        XCTAssertTrue(
            ongoingStay.waitForExistence(timeout: 8),
            "判定中の滞在行が表示されません"
        )
        ongoingStay.tap()

        XCTAssertTrue(
            app.otherElements["stay-candidate-detail-status"].waitForExistence(timeout: 4)
                || app.staticTexts["stay-candidate-detail-status"].waitForExistence(timeout: 1),
            "判定中の滞在行をタップしても詳細が表示されません"
        )
    }

    @MainActor
    func testOngoingStayMapPinOpensDetailsAndPlaceRegistration() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-welcome-onboarding",
            "--debug-onboarding-capture",
            "--debug-onboarding-log",
            "--debug-ongoing-candidate",
            "--debug-map",
            "--debug-map-wide",
            "--debug-pro",
            "-appLanguage",
            "ja",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        let provisionalPin = app.buttons["provisional-map-pin"].firstMatch
        XCTAssertTrue(
            provisionalPin.waitForExistence(timeout: 10),
            "地図に判定中の滞在ピンが表示されません"
        )
        provisionalPin.tap()

        XCTAssertTrue(
            app.otherElements["stay-candidate-detail-status"].waitForExistence(timeout: 4)
                || app.staticTexts["stay-candidate-detail-status"].waitForExistence(timeout: 1),
            "判定中の滞在ピンをタップしても詳細が表示されません"
        )

        let registrationButton = app.buttons["candidate-place-registration-button"]
        XCTAssertTrue(
            registrationButton.waitForExistence(timeout: 3),
            "判定中の滞在詳細に場所登録ボタンが表示されません"
        )
        if registrationButton.isHittable == false {
            app.swipeUp()
        }
        registrationButton.tap()

        XCTAssertTrue(
            app.buttons["この場所を登録"].waitForExistence(timeout: 4),
            "判定中の滞在から場所登録画面を開けません"
        )
    }

    @MainActor
    func testStayLocationEditorUsesFullScreenMapLayout() throws {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "--debug-skip-welcome-onboarding",
                "--debug-onboarding-capture",
                "--debug-map",
                "--debug-map-wide",
                "--debug-pro",
                "--debug-permissions-ready",
                "-appLanguage",
                "ja",
                "-appAppearance",
                appearance,
                "-AppleLanguages",
                "(ja)",
                "-AppleLocale",
                "ja_JP",
            ]
            app.launch()

            let confirmedPin = app.buttons
                .matching(identifier: "confirmed-map-pin")
                .matching(NSPredicate(format: "label == %@", "1番目の訪問"))
                .firstMatch
            XCTAssertTrue(
                confirmedPin.waitForExistence(timeout: 10),
                "\(appearance)表示の地図に確定済み滞在のピンが表示されません"
            )
            confirmedPin.tap()

            let editButton = app.buttons["stay-location-edit-button"]
            XCTAssertTrue(
                editButton.waitForExistence(timeout: 4),
                "\(appearance)表示の滞在詳細に位置修正ボタンが表示されません"
            )
            if editButton.isHittable == false {
                app.swipeUp()
            }
            editButton.tap()

            XCTAssertTrue(
                app.otherElements["stay-location-editor-map"].waitForExistence(timeout: 5),
                "\(appearance)表示で全面地図の位置修正画面が表示されません"
            )
            let editorPin = app.buttons["stay-location-editor-pin"]
            XCTAssertTrue(
                editorPin.waitForExistence(timeout: 3),
                "\(appearance)表示でドラッグ可能な滞在位置ピンが表示されません"
            )
            XCTAssertTrue(app.buttons["キャンセル"].exists)
            let saveButton = app.buttons["stay-location-editor-save"]
            XCTAssertTrue(saveButton.exists)
            XCTAssertFalse(saveButton.isEnabled)
            XCTAssertTrue(
                app.staticTexts["ピンをドラッグして、正しい滞在位置に移動してください。"].exists
            )

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "stay-location-editor-full-screen-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let dragStart = editorPin.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            dragStart.press(
                forDuration: 1,
                thenDragTo: dragStart.withOffset(CGVector(dx: 72, dy: 56)),
                withVelocity: 120,
                thenHoldForDuration: 0.2
            )
            let saveEnabled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"),
                object: saveButton
            )
            guard XCTWaiter.wait(for: [saveEnabled], timeout: 3) == .completed else {
                XCTFail("\(appearance)表示でピンを動かしても保存が有効になりません")
                app.terminate()
                return
            }
            app.terminate()
        }
    }

    @MainActor
    func testSelectingLogStayOpensMatchingMapPin() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--seed-long-timeline",
            "--debug-skip-welcome-onboarding",
            "--debug-pro",
            "-appLanguage",
            "ja",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        let firstStay = app.staticTexts["検証地点 1"]
        XCTAssertTrue(firstStay.waitForExistence(timeout: 5), "ログの滞在が表示されません")
        firstStay.tap()

        let mapTab = app.tabBars.buttons["マップ"]
        XCTAssertTrue(mapTab.waitForExistence(timeout: 3), "マップタブへ遷移できません")
        XCTAssertTrue(mapTab.isSelected, "滞在タップ後にマップタブが選択されていません")
        XCTAssertTrue(
            app.navigationBars["検証地点 1"].waitForExistence(timeout: 4),
            "選択した滞在のピン詳細が表示されません"
        )
    }

    @MainActor
    func testTodayDatePillStaysCenteredOnLaunchAndReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let launchArguments = [
            "--debug-onboarding-history-data", "--debug-skip-welcome-onboarding",
            "--debug-pro", "-automaticExportEnabled", "NO",
            "-appLanguage", "ja", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = Calendar.current.startOfDay(for: Date())
        let todayPill = app.buttons["log-date-chip-\(formatter.string(from: today))"]

        for appearance in ["light", "dark"] {
            app.launchArguments = launchArguments + ["-appAppearance", appearance]
            app.launch()
            XCTAssertTrue(todayPill.waitForExistence(timeout: 10))
            XCTAssertEqual(todayPill.frame.midX, app.frame.midX, accuracy: 2,
                           "初回表示で今日のピルが中央からずれています")
            attachGuidedSetupScreenshot(app, name: "Date pill initial \(appearance)")
            app.swipeRight()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
            let yesterdayPill = app.buttons["log-date-chip-\(formatter.string(from: yesterday))"]
            let yesterdayCentered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    yesterdayPill.label.contains("選択中") &&
                        abs(yesterdayPill.frame.midX - app.frame.midX) <= 2
                },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [yesterdayCentered], timeout: 4), .completed)
            todayPill.tap()
            XCTAssertTrue(app.buttons["今日、選択中"].waitForExistence(timeout: 4))
            XCTAssertEqual(todayPill.frame.midX, app.frame.midX, accuracy: 2,
                           "別日から戻ると今日のピルが中央からずれています")
            attachGuidedSetupScreenshot(app, name: "Date pill returned \(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testSelectedDateCentersAcrossHistoryNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--debug-onboarding-history-data", "--debug-date-selector-history",
            "--debug-skip-welcome-onboarding", "--debug-pro",
            "-automaticExportEnabled", "NO", "-appLanguage", "ja",
            "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = Calendar.current.startOfDay(for: Date())
        func pill(_ offset: Int) -> XCUIElement {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            return app.buttons["log-date-chip-\(formatter.string(from: date))"]
        }
        func assertCentered(_ offset: Int, file: StaticString = #filePath, line: UInt = #line) {
            let selected = pill(offset)
            let centered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    selected.exists && selected.label.contains("選択中") &&
                        abs(selected.frame.midX - app.frame.midX) <= 2
                }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 4), .completed,
                           "日付 \(offset) が中央にありません: \(selected.frame)", file: file, line: line)
        }
        app.launch()
        XCTAssertTrue(pill(0).waitForExistence(timeout: 10))
        assertCentered(0)
        for offset in [-1, -2, -3, -4, -5, -4, -3, -2, -1, 0] {
            pill(offset).tap()
            assertCentered(offset)
        }
        pill(2).tap()
        let rightEdge = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                pill(2).label.contains("選択中") &&
                    abs(pill(2).frame.maxX - (app.frame.maxX - 10)) <= 2
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rightEdge], timeout: 4), .completed)
        XCTAssertFalse(pill(3).exists)
        pill(0).tap()
        assertCentered(0)
        // The strip can browse older dates without changing the selected log.
        // Selecting a browsed pill must still issue a real centering request.
        let selector = app.scrollViews["log-date-selector"]
        func oldestPillIsVisible() -> Bool {
            let oldest = pill(-90)
            guard oldest.exists else { return false }
            let frame = oldest.frame
            return frame.width > 0 && selector.frame.contains(frame)
        }
        for _ in 0..<15 where !oldestPillIsVisible() {
            selector.swipeRight(velocity: .slow)
        }
        XCTAssertTrue(oldestPillIsVisible())
        pill(-90).tap()
        let leftEdge = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                pill(-90).label.contains("選択中") &&
                    abs(pill(-90).frame.minX - (app.frame.minX + 10)) <= 2
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [leftEdge], timeout: 4), .completed)
        XCTAssertFalse(pill(-91).exists)
        pill(-88).tap()
        assertCentered(-88)
        app.swipeLeft()
        assertCentered(-87)
        app.swipeRight()
        assertCentered(-88)
        attachGuidedSetupScreenshot(app, name: "Selected past date centered after history extension")
        app.terminate()
    }

    @MainActor
    func testDatePillPositionSurvivesVerticalHeaderCollapse() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--seed-long-timeline", "--debug-date-selector-history",
            "--debug-skip-welcome-onboarding", "--debug-pro",
            "-automaticExportEnabled", "NO", "-appLanguage", "ja",
            "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let selectedDay = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let selectedPill = app.buttons["log-date-chip-\(formatter.string(from: selectedDay))"]
        app.launch()
        XCTAssertTrue(app.staticTexts["検証地点 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(selectedPill.exists)
        let initialFrame = selectedPill.frame
        XCTAssertEqual(initialFrame.midX, app.frame.midX, accuracy: 2)

        for cycle in 0..<3 {
            app.swipeUp()
            XCTAssertFalse(app.staticTexts["log-screen-title"].isHittable)
            // Bring the header back without changing the selected day.
            for _ in 0..<5 where !app.staticTexts["検証地点 1"].isHittable {
                app.swipeDown()
            }
            app.swipeDown()
            XCTAssertTrue(app.staticTexts["log-screen-title"].isHittable)
            XCTAssertTrue(selectedPill.exists)
            XCTAssertEqual(selectedPill.frame.midX, initialFrame.midX, accuracy: 2,
                           "縦スクロール復帰 \(cycle) で日付欄が横にずれました")
            XCTAssertEqual(selectedPill.frame.minY, initialFrame.minY, accuracy: 2,
                           "縦スクロール復帰後に日付欄の高さが変わりました")
            XCTAssertTrue(selectedPill.label.contains("選択中"))
        }
        attachGuidedSetupScreenshot(app, name: "Date strip after vertical collapse and return")
        app.terminate()
    }

    @MainActor
    func testDatePillBrowsingPositionSurvivesVerticalHeaderCollapse() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--seed-long-timeline", "--debug-date-selector-history",
            "--debug-skip-welcome-onboarding", "--debug-pro",
            "-automaticExportEnabled", "NO", "-appLanguage", "ja",
            "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = Calendar.current.startOfDay(for: Date())
        func pill(_ offset: Int) -> XCUIElement {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            return app.buttons["log-date-chip-\(formatter.string(from: date))"]
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["検証地点 1"].waitForExistence(timeout: 10))
        let selector = app.scrollViews["log-date-selector"]
        for offset in [2, -91] {
            for _ in 0..<15 {
                if pill(offset).exists && pill(offset).frame.width > 0 &&
                    selector.frame.contains(pill(offset).frame) {
                    break
                }
                if offset == 2 {
                    selector.swipeLeft(velocity: .slow)
                } else {
                    selector.swipeRight(velocity: .slow)
                }
            }
            // Fully settle at the real content boundary.
            if offset == 2 { selector.swipeLeft() } else { selector.swipeRight() }
            let anchorFrame = pill(offset).frame
            if offset == 2 {
                XCTAssertEqual(anchorFrame.maxX, app.frame.maxX - 10, accuracy: 2)
            } else {
                XCTAssertEqual(anchorFrame.minX, app.frame.minX + 10, accuracy: 2)
            }
            for _ in 0..<20 where !app.staticTexts["検証地点 18"].isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(app.staticTexts["検証地点 18"].isHittable)
            XCTAssertFalse(app.staticTexts["log-screen-title"].isHittable)
            for _ in 0..<20 where !app.staticTexts["検証地点 1"].isHittable {
                app.swipeDown()
            }
            app.swipeDown()
            XCTAssertTrue(app.staticTexts["log-screen-title"].isHittable)
            XCTAssertTrue(pill(offset).exists)
            XCTAssertEqual(pill(offset).frame.midX, anchorFrame.midX, accuracy: 2,
                           "縦スクロール復帰で、横に動かしていた日付欄の位置が失われました")
            XCTAssertTrue(app.staticTexts["検証地点 1"].isHittable)
            attachGuidedSetupScreenshot(app, name: "Browsed date strip at \(offset) after collapse")
        }
        app.terminate()
    }

    @MainActor
    func testDatePillStaysCenteredAfterHistoryTodayAndHeaderReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--seed-long-timeline", "--debug-date-selector-history", "--debug-header-today-return",
            "--debug-skip-welcome-onboarding", "--debug-pro",
            "-automaticExportEnabled", "NO", "-appLanguage", "ja",
            "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = Calendar.current.startOfDay(for: Date())
        func pill(_ offset: Int) -> XCUIElement {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            return app.buttons["log-date-chip-\(formatter.string(from: date))"]
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["検証地点 1"].waitForExistence(timeout: 10))
        let selector = app.scrollViews["log-date-selector"]
        for _ in 0..<15 {
            if pill(-42).exists && pill(-42).frame.width > 0 &&
                selector.frame.contains(pill(-42).frame) { break }
            selector.swipeRight(velocity: .slow)
        }
        selector.swipeRight()
        pill(-42).tap()
        XCTAssertTrue(app.buttons["log-return-to-today"].waitForExistence(timeout: 5))
        app.buttons["log-return-to-today"].tap()
        let centered = NSPredicate { _, _ in
            pill(0).exists && pill(0).label.contains("選択中") &&
                abs(pill(0).frame.midX - app.frame.midX) <= 2
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: centered, evaluatedWith: app)], timeout: 5), .completed)
        attachGuidedSetupScreenshot(app, name: "Today after returning from oldest date")
        for _ in 0..<20 where !app.staticTexts["検証地点 18"].isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["検証地点 18"].isHittable)
        XCTAssertFalse(app.staticTexts["log-screen-title"].isHittable)
        for _ in 0..<20 where !app.staticTexts["検証地点 1"].isHittable {
            app.swipeDown()
        }
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["log-screen-title"].isHittable)
        attachGuidedSetupScreenshot(app, name: "Today after history return and vertical collapse")
        XCTAssertTrue(pill(0).exists)
        XCTAssertEqual(pill(0).frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertTrue(pill(0).label.contains("選択中"))
        app.terminate()
    }

    @MainActor
    func testLongTimelineScrollAndDayPaging() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--seed-long-timeline",
            "--debug-skip-welcome-onboarding",
            "--debug-pro",
            "-appLanguage",
            "ja",
            "-AppleLanguages",
            "(ja)",
            "-AppleLocale",
            "ja_JP",
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["検証地点 1"].waitForExistence(timeout: 5),
            "ログの先頭が起動直後に表示されていません"
        )

        let lastStay = app.staticTexts["検証地点 18"]
        for _ in 0..<20 where lastStay.isHittable == false {
            app.swipeUp()
        }

        XCTAssertTrue(lastStay.isHittable, "長いログを末尾までスクロールできません")
        XCTAssertFalse(
            app.staticTexts["log-screen-title"].isHittable,
            "ログ見出しが縦スクロール後も画面に残っています"
        )

        let bottomScreenshot = XCTAttachment(screenshot: app.screenshot())
        bottomScreenshot.name = "Long timeline bottom"
        bottomScreenshot.lifetime = .keepAlways
        add(bottomScreenshot)

        app.swipeLeft()

        let todaySelection = app.buttons["今日、選択中"]
        XCTAssertTrue(
            todaySelection.waitForExistence(timeout: 4),
            "左スワイプで翌日へ移動できません"
        )

        let nextDayScreenshot = XCTAttachment(screenshot: app.screenshot())
        nextDayScreenshot.name = "Next day after horizontal swipe"
        nextDayScreenshot.lifetime = .keepAlways
        add(nextDayScreenshot)

        // The selector includes today plus two future days for visual balance,
        // without reopening unlimited future paging.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func dateChip(offset: Int) -> XCUIElement {
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            return app.buttons["log-date-chip-\(formatter.string(from: date))"]
        }
        XCTAssertTrue(dateChip(offset: 1).exists)
        XCTAssertTrue(dateChip(offset: 2).exists)
        XCTAssertFalse(dateChip(offset: 3).exists)
        dateChip(offset: 2).tap()
        XCTAssertTrue(app.staticTexts["未来の日付には位置ログはありません。"].waitForExistence(timeout: 4))
        app.swipeLeft()
        XCTAssertFalse(dateChip(offset: 3).exists)
        XCTAssertTrue(dateChip(offset: 2).label.contains("選択中"))
        let futureScreenshot = XCTAttachment(screenshot: app.screenshot())
        futureScreenshot.name = "Future dates stop after today plus two days"
        futureScreenshot.lifetime = .keepAlways
        add(futureScreenshot)
        dateChip(offset: 0).tap()
        XCTAssertTrue(todaySelection.waitForExistence(timeout: 4))

        app.swipeRight()

        let seededDay = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let seededDayComponents = Calendar.current.dateComponents([.month, .day], from: seededDay)
        let seededDaySelection = app.buttons[
            "\(seededDayComponents.month ?? 0)/\(seededDayComponents.day ?? 0)、選択中"
        ]
        XCTAssertTrue(
            seededDaySelection.waitForExistence(timeout: 4),
            "右スワイプでシード日の選択状態へ戻れません"
        )
        XCTAssertTrue(
            lastStay.waitForExistence(timeout: 4),
            "右スワイプでシード日のログへ戻れません"
        )
    }

    @MainActor
    private func assertLoadedPaywallPrice(
        _ priceElement: XCUIElement,
        planName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let loadedPriceExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND label != '' AND label != %@ AND label != %@",
                "Loading prices",
                "Reload Prices"
            ),
            object: priceElement
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [loadedPriceExpectation], timeout: 8),
            .completed,
            "\(planName)の商品価格がPaywallに表示されません",
            file: file,
            line: line
        )
    }
}
