import Foundation
import XCTest
@testable import CodexUsageMonitor

final class CodexAppServerClientTests: XCTestCase {
    func testLiveAccountWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_CODEX_TEST=1 to query the current Codex account")
        }

        let snapshot = try await CodexAppServerClient(timeout: 15).fetchSnapshot()

        XCTAssertEqual(snapshot.primaryLimit.limitId, "codex")
        XCTAssertNotNil(snapshot.primaryLimit.remainingPercent)
        XCTAssertNotNil(snapshot.lifetimeTokens)
        print("LIVE_CODEX remaining=\(snapshot.primaryLimit.remainingPercent ?? -1) lifetime=\(snapshot.lifetimeTokens ?? -1) dailyBuckets=\(snapshot.dailyUsageBuckets.count)")
    }

    func testParsesOutOfOrderResponsesAndIgnoresNotifications() async throws {
        let lines = [
            #"{"method":"account/rateLimits/updated","params":{}}"#,
            #"{"id":3,"result":{"summary":{"lifetimeTokens":123456},"dailyUsageBuckets":[{"startDate":"2026-07-15","tokens":42}]}}"#,
            #"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":1784787454}},"rateLimitsByLimitId":{"spark":{"limitId":"spark","limitName":"Spark","primary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1784787454}},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":1784787454}}}}}"#
        ].map { Data($0.utf8) }
        let client = CodexAppServerClient(
            executor: FakeExecutor(result: AppServerExchangeResult(stdoutLines: lines)),
            executableURL: URL(fileURLWithPath: "/usr/bin/false")
        )

        let snapshot = try await client.fetchSnapshot()

        XCTAssertEqual(snapshot.primaryLimit.remainingPercent, 73)
        XCTAssertEqual(snapshot.otherLimits.map(\.displayName), ["Spark"])
        XCTAssertEqual(snapshot.lifetimeTokens, 123456)
        XCTAssertEqual(snapshot.dailyUsageBuckets.first?.tokens, 42)
    }

    func testClampsRemainingPercentage() async throws {
        let lines = Self.responses(usedPercent: 140)
        let client = CodexAppServerClient(
            executor: FakeExecutor(result: AppServerExchangeResult(stdoutLines: lines)),
            executableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        let snapshot = try await client.fetchSnapshot()
        XCTAssertEqual(snapshot.primaryLimit.remainingPercent, 0)
    }

    func testMapsNonzeroExitAndTimeout() async {
        let failing = CodexAppServerClient(
            executor: FakeExecutor(result: AppServerExchangeResult(stdoutLines: [], stderr: "boom", terminationStatus: 2)),
            executableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        do {
            _ = try await failing.fetchSnapshot()
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .processFailed("boom"))
        }

        let timeout = CodexAppServerClient(
            executor: FakeExecutor(error: CodexUsageError.timedOut),
            executableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        do {
            _ = try await timeout.fetchSnapshot()
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .timedOut)
        }
    }

    private static func responses(usedPercent: Int) -> [Data] {
        [
            Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":\#(usedPercent),"windowDurationMins":10080,"resetsAt":null}},"rateLimitsByLimitId":null}}"#.utf8),
            Data(#"{"id":3,"result":{"summary":{"lifetimeTokens":0},"dailyUsageBuckets":[]}}"#.utf8)
        ]
    }
}

private struct FakeExecutor: AppServerProcessExecuting {
    let result: AppServerExchangeResult?
    let error: (any Error)?

    init(result: AppServerExchangeResult) {
        self.result = result
        self.error = nil
    }

    init(error: any Error) {
        self.result = nil
        self.error = error
    }

    func exchange(executableURL: URL, timeout: TimeInterval) async throws -> AppServerExchangeResult {
        if let error { throw error }
        return try XCTUnwrap(result)
    }
}
