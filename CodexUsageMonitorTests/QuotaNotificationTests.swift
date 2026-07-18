import Foundation
import XCTest
@testable import CodexUsageMonitor

final class QuotaNotificationTests: XCTestCase {
    func testFirstObservationOnlyCreatesBaseline() {
        let persistence = MemoryObservationStore()
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertNil(tracker.observe(remainingPercent: 100, resetsAt: 200, sevenDayTokens: 10))
        XCTAssertEqual(persistence.state, QuotaObservationState(lastRemainingPercent: 100, lastResetsAt: 200))
    }

    func testFirstLowObservationDoesNotNotifyLaterInSameCycle() {
        let persistence = MemoryObservationStore()
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertNil(tracker.observe(remainingPercent: 15, resetsAt: 200, sevenDayTokens: 10))
        XCTAssertNil(tracker.observe(remainingPercent: 10, resetsAt: 200, sevenDayTokens: 10))
        XCTAssertEqual(persistence.state?.lowQuotaNotifiedResetsAt, 200)
    }

    func testNinetyNineToHundredTriggersReset() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 99, lastResetsAt: 100))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertEqual(
            tracker.observe(remainingPercent: 100, resetsAt: 200, sevenDayTokens: 123),
            .reset(currentRemaining: 100, nextResetAt: 200, sevenDayTokens: 123)
        )
    }

    func testTwentyFiveToHundredTriggersReset() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 25, lastResetsAt: 100))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertEqual(
            tracker.observe(remainingPercent: 100, resetsAt: 200, sevenDayTokens: 123),
            .reset(currentRemaining: 100, nextResetAt: 200, sevenDayTokens: 123)
        )
    }

    func testRepeatedHundredDoesNotNotifyAndTracksLatestResetTime() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 100, lastResetsAt: 100))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertNil(tracker.observe(remainingPercent: 100, resetsAt: 200, sevenDayTokens: 123))
        XCTAssertEqual(persistence.state?.lastResetsAt, 200)
        XCTAssertNil(tracker.observe(remainingPercent: 100, resetsAt: 300, sevenDayTokens: 123))
        XCTAssertEqual(persistence.state?.lastResetsAt, 300)
    }

    func testLeavingHundredDoesNotNotify() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 100, lastResetsAt: 200))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertNil(tracker.observe(remainingPercent: 99, resetsAt: 200, sevenDayTokens: 123))
    }

    func testResetTimeAdvanceWithoutHundredDoesNotNotify() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 25, lastResetsAt: 100))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertNil(tracker.observe(remainingPercent: 96, resetsAt: 200, sevenDayTokens: 123))
        XCTAssertEqual(
            persistence.state,
            QuotaObservationState(lastRemainingPercent: 96, lastResetsAt: 200)
        )
    }

    func testResetTimeRegressionWithoutHundredDoesNotNotify() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 25, lastResetsAt: 200))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertNil(tracker.observe(remainingPercent: 24, resetsAt: 150, sevenDayTokens: 123))
        XCTAssertEqual(
            persistence.state,
            QuotaObservationState(lastRemainingPercent: 24, lastResetsAt: 150)
        )
    }

    func testLowQuotaCrossingTriggersOncePerCycle() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 21, lastResetsAt: 200))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertEqual(
            tracker.observe(remainingPercent: 18, resetsAt: 200, sevenDayTokens: 0),
            .lowQuota(currentRemaining: 18, resetAt: 200)
        )
        XCTAssertNil(tracker.observe(remainingPercent: 10, resetsAt: 200, sevenDayTokens: 0))
    }

    func testResetTimeAdvanceAtLowQuotaDoesNotNotifyAndMarksLowHandled() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 5, lastResetsAt: 100))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertNil(tracker.observe(remainingPercent: 19, resetsAt: 200, sevenDayTokens: 99))
        XCTAssertEqual(persistence.state?.lowQuotaNotifiedResetsAt, 200)
        XCTAssertNil(tracker.observe(remainingPercent: 18, resetsAt: 200, sevenDayTokens: 99))
    }

    func testNotificationContentIncludesRequestedDetails() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let event = QuotaNotificationEvent.reset(
            currentRemaining: 100,
            nextResetAt: 1_784_787_454,
            sevenDayTokens: 1_917_054_579
        )

        let content = event.content(timeZone: timeZone)
        XCTAssertEqual(content.identifier, "quota-reset-1784787454")
        XCTAssertEqual(content.title, "Codex 周额度已重置")
        XCTAssertTrue(content.body.contains("当前剩余 100%"))
        XCTAssertTrue(content.body.contains("19.17 亿 tokens"))
        XCTAssertTrue(content.body.contains("下次重置"))
    }
}

final class MemoryObservationStore: QuotaObservationStatePersisting {
    var state: QuotaObservationState?

    init(state: QuotaObservationState? = nil) { self.state = state }
    func load() -> QuotaObservationState? { state }
    func save(_ state: QuotaObservationState) { self.state = state }
}
