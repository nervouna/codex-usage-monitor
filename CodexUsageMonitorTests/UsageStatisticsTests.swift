import XCTest
@testable import CodexUsageMonitor

final class UsageStatisticsTests: XCTestCase {
    func testUsesCompleteDaysAndFillsMissingDatesWithZero() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12)))
        let buckets = [
            DailyUsageBucket(startDate: "2026-07-15", tokens: 70),
            DailyUsageBucket(startDate: "2026-07-14", tokens: 35),
            DailyUsageBucket(startDate: "2026-07-09", tokens: 7),
            DailyUsageBucket(startDate: "2026-07-16", tokens: 9_999)
        ]

        let stats = UsageStatistics.calculate(buckets: buckets, now: now, calendar: calendar)

        XCTAssertEqual(stats.sevenDayTotal, 112)
        XCTAssertEqual(stats.sevenDayAverage, 16)
        XCTAssertEqual(stats.thirtyDayTotal, 112)
        XCTAssertEqual(stats.thirtyDayAverage, 3)
    }

    func testHandlesCrossMonthAndLeapDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 3, day: 2, hour: 8)))
        let buckets = [
            DailyUsageBucket(startDate: "2024-03-01", tokens: 10),
            DailyUsageBucket(startDate: "2024-02-29", tokens: 20),
            DailyUsageBucket(startDate: "2024-02-28", tokens: 30)
        ]

        let stats = UsageStatistics.calculate(buckets: buckets, now: now, calendar: calendar)
        XCTAssertEqual(stats.sevenDayTotal, 60)
    }

    func testEmptyBucketsReturnZero() {
        let stats = UsageStatistics.calculate(buckets: [])
        XCTAssertEqual(stats, UsageStatistics(sevenDayTotal: 0, sevenDayAverage: 0, thirtyDayTotal: 0, thirtyDayAverage: 0))
    }
}
