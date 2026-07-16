import Foundation
import XCTest
@testable import CodexUsageMonitor

@MainActor
final class UsageStoreTests: XCTestCase {
    func testRefreshSuccessThenFailureKeepsLastSnapshot() async {
        let snapshot = Self.snapshot()
        let fetcher = SequenceFetcher(results: [.success(snapshot), .failure(CodexUsageError.timedOut)])
        let store = makeStore(fetcher: fetcher, now: { Date(timeIntervalSince1970: 1_800_000_000) })

        await store.refresh()
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNil(store.errorMessage)

        await store.refresh()
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertTrue(store.isStale)
        XCTAssertNotNil(store.errorMessage)
    }

    func testConcurrentRefreshIsDeduplicated() async {
        let fetcher = SlowFetcher(snapshot: Self.snapshot())
        let store = makeStore(fetcher: fetcher)

        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        let count = await fetcher.callCount
        XCTAssertEqual(count, 1)
    }

    func testFirstPopoverRequestsPermissionOnlyOnce() async {
        let manager = FakeNotificationManager(status: .notDetermined, requestedStatus: .denied)
        let defaults = makeDefaults()
        let store = UsageStore(
            fetcher: StaticFetcher(snapshot: Self.snapshot()),
            notificationManager: manager,
            observationPersistence: MemoryObservationStore(),
            preferences: defaults
        )

        await store.handlePopoverOpened()
        await store.handlePopoverOpened()

        XCTAssertEqual(manager.requestCount, 1)
        XCTAssertEqual(store.notificationAuthorizationStatus, .denied)
        XCTAssertTrue(store.notificationsEnabled)
    }

    func testRefreshDeliversResetWithSevenDayUsageWhenAuthorized() async {
        let manager = FakeNotificationManager(status: .authorized)
        let persistence = MemoryObservationStore(
            state: .init(lastRemainingPercent: 25, lastResetsAt: 100)
        )
        let snapshot = Self.snapshot(
            usedPercent: 0,
            resetsAt: 200,
            dailyUsageBuckets: [DailyUsageBucket(startDate: Self.yesterdayKey(), tokens: 700)]
        )
        let store = UsageStore(
            fetcher: StaticFetcher(snapshot: snapshot),
            notificationManager: manager,
            observationPersistence: persistence,
            preferences: makeDefaults()
        )

        await store.refresh()

        XCTAssertEqual(
            manager.delivered,
            [.reset(currentRemaining: 100, nextResetAt: 200, sevenDayTokens: 700)]
        )
    }

    func testDisabledNotificationsStillAdvanceObservationState() async {
        let manager = FakeNotificationManager(status: .authorized)
        let persistence = MemoryObservationStore(
            state: .init(lastRemainingPercent: 25, lastResetsAt: 100)
        )
        let defaults = makeDefaults()
        defaults.set(false, forKey: "quotaNotificationsEnabled")
        let store = UsageStore(
            fetcher: StaticFetcher(snapshot: Self.snapshot(usedPercent: 0, resetsAt: 200)),
            notificationManager: manager,
            observationPersistence: persistence,
            preferences: defaults
        )

        await store.refresh()

        XCTAssertTrue(manager.delivered.isEmpty)
        XCTAssertEqual(persistence.state?.lastResetsAt, 200)
    }

    private func makeStore(
        fetcher: any UsageFetching,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> UsageStore {
        UsageStore(
            fetcher: fetcher,
            now: now,
            notificationManager: FakeNotificationManager(status: .denied),
            observationPersistence: MemoryObservationStore(),
            preferences: makeDefaults()
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "UsageStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func snapshot(
        usedPercent: Int = 25,
        resetsAt: Int64? = 200,
        dailyUsageBuckets: [DailyUsageBucket] = []
    ) -> UsageSnapshot {
        UsageSnapshot(
            primaryLimit: RateLimitSnapshot(
                limitId: "codex",
                primary: RateLimitWindow(usedPercent: usedPercent, resetsAt: resetsAt)
            ),
            dailyUsageBuckets: dailyUsageBuckets,
            lifetimeTokens: 10,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func yesterdayKey() -> String {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        let parts = calendar.dateComponents([.year, .month, .day], from: yesterday)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

private actor SequenceFetcher: UsageFetching {
    private var results: [Result<UsageSnapshot, CodexUsageError>]

    init(results: [Result<UsageSnapshot, CodexUsageError>]) { self.results = results }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard !results.isEmpty else { throw CodexUsageError.protocolChanged("测试序列耗尽") }
        return try results.removeFirst().get()
    }
}

private actor SlowFetcher: UsageFetching {
    private(set) var callCount = 0
    let snapshot: UsageSnapshot

    init(snapshot: UsageSnapshot) { self.snapshot = snapshot }

    func fetchSnapshot() async throws -> UsageSnapshot {
        callCount += 1
        try await Task.sleep(for: .milliseconds(50))
        return snapshot
    }
}

private struct StaticFetcher: UsageFetching {
    let snapshot: UsageSnapshot
    func fetchSnapshot() async throws -> UsageSnapshot { snapshot }
}

private final class FakeNotificationManager: QuotaNotificationManaging {
    var status: QuotaNotificationAuthorizationStatus
    var requestedStatus: QuotaNotificationAuthorizationStatus
    var requestCount = 0
    var delivered: [QuotaNotificationEvent] = []

    init(
        status: QuotaNotificationAuthorizationStatus,
        requestedStatus: QuotaNotificationAuthorizationStatus? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus ?? status
    }

    func authorizationStatus() async -> QuotaNotificationAuthorizationStatus { status }

    func requestAuthorization() async -> QuotaNotificationAuthorizationStatus {
        requestCount += 1
        status = requestedStatus
        return status
    }

    func deliver(_ event: QuotaNotificationEvent) async throws {
        delivered.append(event)
    }
}
