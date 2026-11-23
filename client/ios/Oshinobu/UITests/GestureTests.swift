import XCTest

/// Жесты, которые нельзя проверить по скриншоту: нажимает «пальцем» на устройстве.
/// Скриншоты по ходу — снаружи (devicectl), тест только держит касание.
final class GestureTests: XCTestCase {
    private func launchChat(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-openChat", "first"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["recordButton"].waitForExistence(timeout: 15))
        sleep(2)
        return app
    }

    /// Удержать кнопку записи 5 с (снаружи в это время снимается экран) и отпустить.
    func testHoldRecord() {
        let app = launchChat()
        app.descendants(matching: .any)["recordButton"].press(forDuration: 5)
        sleep(2)
    }

    /// Удержать и потянуть вверх до замочка, отпустить (запись остаётся), затем «отменить запись».
    func testLockRecord() {
        let app = launchChat()
        let button = app.descendants(matching: .any)["recordButton"]
        let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        sleep(3)
        let cancel = app.descendants(matching: .any)["cancelRecording"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "после фиксации нет «отменить запись»")
        cancel.tap()
        sleep(1)
    }

    /// Нажатие переключает на кружок; удержание пишет его, уводим влево — отмена.
    func testHoldVideoCancel() {
        let app = launchChat()
        let button = app.descendants(matching: .any)["recordButton"]
        button.tap()
        sleep(1)
        let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 4, thenDragTo: start.withOffset(CGVector(dx: -260, dy: 0)))
        sleep(2)
        button.tap() // обратно на микрофон
    }

    /// Клавиатура поднята → скрепка → медиа: шторка открывается без клавиатуры (снаружи — скриншоты).
    func testAttachHidesKeyboard() {
        let app = launchChat()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["attachButton"].tap()
        sleep(1)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "скрепка убрала клавиатуру")
        app.descendants(matching: .any)["attachMedia"].tap()
        sleep(2)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "клавиатура осталась поверх шторки")
        sleep(2)
    }

    /// Кружок с фиксацией: камера туда и обратно, отправка нажатием (уходит настоящий кружок).
    func testVideoFlipSend() {
        let app = launchChat()
        let button = app.descendants(matching: .any)["recordButton"]
        button.tap()
        sleep(1)
        let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.5, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))
        sleep(2)
        let flip = app.descendants(matching: .any)["flipCamera"]
        XCTAssertTrue(flip.waitForExistence(timeout: 3))
        flip.tap()
        sleep(2)
        flip.tap()
        sleep(2)
        button.tap() // в фиксации — отправить
        sleep(4)
        button.tap() // обратно на микрофон
    }

    /// Ряд тем внизу экрана «Тема» листается пальцем.
    func testThemeRowScrolls() {
        let app = XCUIApplication()
        app.launchArguments = ["-openRoute", "theme"]
        app.launch()
        sleep(6)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.92))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.92)))
        sleep(3)
    }

    /// Поиск: нашли, ленту увели, стрелка возвращает к совпадению; «назад» закрывает поиск.
    func testSearchJumpAndBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-openChat", "first", "-debugSearch", "hi"]
        app.launch()
        sleep(8)
        // увести ленту вниз (к новым)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        sleep(2)
        app.descendants(matching: .any)["searchOlder"].tap()
        sleep(3)
        app.descendants(matching: .any)["searchBack"].firstMatch.tap()
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any)["searchBack"].firstMatch.exists, "поиск не закрылся")
    }

    /// Кнопка с подсветкой (RippleStyle) нажимается: пункт настроек открывает окно.
    func testRippleButtonTaps() {
        let app = XCUIApplication()
        app.launchArguments = ["-startTab", "settings"]
        app.launch()
        sleep(6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.355)).tap()
        sleep(3)
    }

    /// «Назад» в шапке чата.
    func testChatBack() {
        let app = launchChat()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.087)).tap()
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any)["recordButton"].exists, "чат не закрылся")
    }

    /// «Назад» в поиске сразу, без прокрутки (клавиатура поднята).
    func testSearchBackDirect() {
        let app = XCUIApplication()
        app.launchArguments = ["-openChat", "first", "-debugSearch", "hi"]
        app.launch()
        sleep(8)
        let back = app.descendants(matching: .any)["searchBack"].firstMatch
        back.tap()
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any)["searchBack"].firstMatch.exists, "поиск не закрылся")
    }

    /// Свайп вправо по ряду тем — листание ряда, а не «назад».
    func testThemeRowNoBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-openRoute", "theme"]
        app.launch()
        sleep(6)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.92))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.92)))
        sleep(2)
        XCTAssertTrue(app.staticTexts["Bob"].exists, "свайп по ряду тем закрыл экран")
    }

    /// Поиск собеседника по логину на главном экране: найти и открыть чат.
    func testUserSearch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 20))
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.925, dy: 0.094)).tap()
        sleep(1)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "нет поля поиска")
        field.typeText("test")
        sleep(4)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.17)).tap()
        sleep(4)
    }

    /// «Показать списком» → нажатие на совпадение переносит к нему в ленте.
    func testSearchListPick() {
        let app = XCUIApplication()
        app.launchArguments = ["-openChat", "first", "-debugSearch", "hi", "-debugSearchList", "YES"]
        app.launch()
        sleep(8)
        app.staticTexts["Hi"].firstMatch.tap()
        sleep(4)
    }

    /// Галерея → просмотр фото → эмодзи в подписи открывает панель эмодзи (без стикеров).
    func testCaptionEmoji() {
        let app = launchChat()
        app.descendants(matching: .any)["attachButton"].tap()
        sleep(1)
        app.descendants(matching: .any)["attachMedia"].tap()
        sleep(3)
        // вторая плитка первого ряда, ближе к низу — просмотр (угол — выбор)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).tap()
        sleep(3)
        app.descendants(matching: .any)["captionEmoji"].firstMatch.tap()
        sleep(3)
    }

    /// Свайп по пункту настроек (листание вкладок) — не нажатие: окно не открывается.
    func testSettingsSwipeNoTap() {
        let app = XCUIApplication()
        app.launchArguments = ["-startTab", "settings"]
        app.launch()
        sleep(6)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.355))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.355)))
        sleep(2)
        XCTAssertFalse(app.staticTexts["Russian"].exists, "свайп открыл окно языка")
    }

    /// Просмотр фото из галереи: эмодзи → клавиатура; фото и подпись не прыгают (снаружи — скриншоты).
    func testPreviewCaptionKeyboard() {
        let app = launchChat()
        app.descendants(matching: .any)["attachButton"].tap()
        sleep(1)
        app.descendants(matching: .any)["attachMedia"].tap()
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)).tap()
        sleep(3)
        let emoji = app.descendants(matching: .any)["captionEmoji"].firstMatch
        emoji.tap()
        sleep(3)
        emoji.tap()
        sleep(4)
    }

    /// Галерея: выбрать плитку (кружок), ткнуть в подпись — плитки не съезжают, чат за шторкой стоит.
    func testGallerySelectCaption() {
        let app = launchChat()
        app.descendants(matching: .any)["attachButton"].tap()
        sleep(1)
        app.descendants(matching: .any)["attachMedia"].tap()
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.375)).tap()
        sleep(2)
        app.textViews.firstMatch.exists ? app.textViews.firstMatch.tap() : app.textFields.firstMatch.tap()
        sleep(4)
    }

    /// Шторка галереи: потянуть сетку вниз немного — вернётся; дотянуть до нижней четверти — закроется.
    func testGalleryPullDown() {
        let app = launchChat()
        app.descendants(matching: .any)["attachButton"].tap()
        sleep(1)
        app.descendants(matching: .any)["attachMedia"].tap()
        sleep(3)
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        a.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        XCTAssertTrue(app.descendants(matching: .any)["attachMedia"].exists == false)
        a.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
    }
}
