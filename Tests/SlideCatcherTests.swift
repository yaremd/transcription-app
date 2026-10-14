import XCTest
@testable import Seal

/// When the call's window has settled on a new slide, and whether what was
/// read off it is worth keeping.
final class SlideCatcherTests: XCTestCase {

    private func picture(_ shade: (_ column: Int, _ row: Int) -> UInt8) -> Thumbprint {
        var cells: [UInt8] = []
        for row in 0..<Thumbprint.rows {
            for column in 0..<Thumbprint.columns { cells.append(shade(column, row)) }
        }
        return Thumbprint(cells: cells)
    }

    private lazy var slideA = picture { _, row in row % 4 == 0 ? 40 : 230 }
    private lazy var slideB = picture { column, row in row % 3 == 0 && column < 48 ? 40 : 230 }

    func testASettledPictureIsReadOnce() {
        var watch = SettleWatch()
        XCTAssertFalse(watch.observe(slideA), "nothing to compare the first glance with")
        XCTAssertFalse(watch.observe(slideA), "still once is not settled yet")
        XCTAssertTrue(watch.observe(slideA))
        watch.markRead()
        XCTAssertFalse(watch.observe(slideA))
        XCTAssertFalse(watch.observe(slideA))
    }

    func testTheNextSlideIsReadOnceItSettles() {
        var watch = SettleWatch()
        _ = watch.observe(slideA)
        _ = watch.observe(slideA)
        XCTAssertTrue(watch.observe(slideA))
        watch.markRead()
        XCTAssertFalse(watch.observe(slideB), "it just changed")
        XCTAssertFalse(watch.observe(slideB))
        XCTAssertTrue(watch.observe(slideB))
    }

    func testAVideoTileThatKeepsMovingDoesNotKeepTheSlideFromSettling() {
        var watch = SettleWatch()
        func glance(_ t: Int) -> Thumbprint {
            picture { column, row in
                column < 12 && row < 8 ? UInt8((t * 70) % 256) : (row % 4 == 0 ? 40 : 230)
            }
        }
        let settledAt = (0..<10).first { watch.observe(glance($0)) }
        XCTAssertNotNil(settledAt, "the tile is learned as video and left out")
    }

    func testAWindowThatIsMostlyVideoNeverSettles() {
        var watch = SettleWatch()
        for t in 0..<12 {
            let frame = picture { column, row in column < 56 ? UInt8((t * 70 + column + row) % 256) : 230 }
            XCTAssertFalse(watch.observe(frame))
        }
    }

    func testOnlyContentWithNewWordsIsKept() {
        let slide = ["Q3 launch plan", "Ship the beta to fifty customers", "Hire two engineers"]
        XCTAssertTrue(SlideCatcher.isWorthKeeping(slide, after: []))
        let names = ["Dmytro Yaremchuk", "Anna Smith", "John"]
        XCTAssertFalse(SlideCatcher.isWorthKeeping(names, after: []), "name labels under video tiles")
        let seen = Set(slide.flatMap { SlideCatcher.words(in: $0) })
        XCTAssertFalse(SlideCatcher.isWorthKeeping(slide, after: [seen]), "the same slide shown again")
        let next = ["Risks", "The vendor contract renews in March", "Budget review moved to Thursday"]
        XCTAssertTrue(SlideCatcher.isWorthKeeping(next, after: [seen]))
    }

    func testTheCallAppsOwnBarsAreLeftOut() {
        let lines = [
            ScreenTextReader.ReadLine(text: "Weekly sync · 42:10", box: CGRect(x: 0.3, y: 0.95, width: 0.4, height: 0.03)),
            ScreenTextReader.ReadLine(text: "Ship the beta", box: CGRect(x: 0.2, y: 0.5, width: 0.5, height: 0.05)),
            ScreenTextReader.ReadLine(text: "Mute Stop Video Participants Share", box: CGRect(x: 0.1, y: 0.02, width: 0.8, height: 0.04)),
        ]
        XCTAssertEqual(SlideCatcher.contentLines(lines), ["Ship the beta"])
    }

    func testOnlyBrowserWindowsTitledLikeAMeetingAreWatched() {
        XCTAssertTrue(SlideCatcher.looksLikeMeeting("Meet – abc-defg-hij - Google Chrome"))
        XCTAssertTrue(SlideCatcher.looksLikeMeeting("Weekly sync | Microsoft Teams"))
        XCTAssertFalse(SlideCatcher.looksLikeMeeting("Inbox (3) - Gmail"))
        XCTAssertFalse(SlideCatcher.looksLikeMeeting("Meetup: Swift London"))
    }
}
