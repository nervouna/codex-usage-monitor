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

    func testCycleAdvanceTriggersResetOnceEvenWhenExactHundredWasMissed() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 25, lastResetsAt: 100))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertEqual(
            tracker.observe(remainingPercent: 96, resetsAt: 200, sevenDayTokens: 123),
            .reset(currentRemaining: 96, nextResetAt: 200, sevenDayTokens: 123)
        )
        XCTAssertNil(tracker.observe(remainingPercent: 95, resetsAt: 200, sevenDayTokens: 123))
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

    func testResetAtLowQuotaProducesOnlyResetAndMarksLowHandled() {
        let persistence = MemoryObservationStore(state: .init(lastRemainingPercent: 5, lastResetsAt: 100))
        let tracker = QuotaNotificationTracker(persistence: persistence)

        XCTAssertEqual(
            tracker.observe(remainingPercent: 19, resetsAt: 200, sevenDayTokens: 99),
            .reset(currentRemaining: 19, nextResetAt: 200, sevenDayTokens: 99)
        )
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
