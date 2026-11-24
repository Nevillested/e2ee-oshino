import XCTest
@testable import OshinobuCore

/// Текст жалобы: у вложений и стикеров он не пустой (пустой сервер отклоняет).
final class ReportTextTests: XCTestCase {
    func testReportText() {
        XCTAssertEqual(StoredMessage(messageId: "1", text: "привет", isMine: false, timestamp: 0).reportText, "привет")

        var sticker = StoredMessage(messageId: "2", text: "", isMine: false, timestamp: 0)
        sticker.stickerId = "s1"
        XCTAssertEqual(sticker.reportText, "sticker:s1")

        var photo = StoredMessage(messageId: "3", text: "", isMine: false, timestamp: 0)
        photo.isMedia = true
        photo.mediaId = "m1"
        XCTAssertEqual(photo.reportText, "[photo media:m1]")

        var file = StoredMessage(messageId: "4", text: "подпись", isMine: false, timestamp: 0)
        file.isMedia = true
        file.isFile = true
        file.fileName = "doc.pdf"
        file.mediaId = "m2"
        XCTAssertEqual(file.reportText, "[file doc.pdf media:m2] подпись")
    }
}
