import Foundation

public struct RateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMins: Int64?
    public let resetsAt: Int64?

    public init(usedPercent: Int, windowDurationMins: Int64? = nil, resetsAt: Int64? = nil) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public struct RateLimitSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?

    public var id: String { limitId ?? limitName ?? "unknown" }
    public var displayName: String { limitName ?? (limitId == "codex" ? "Codex" : limitId ?? "其他额度") }
    public var remainingPercent: Int? {
        primary.map { min(100, max(0, 100 - $0.usedPercent)) }
    }
    public var resetDate: Date? {
        primary?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public init(limitId: String?, limitName: String? = nil, primary: RateLimitWindow?) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
    }
}

public struct DailyUsageBucket: Codable, Equatable, Sendable {
    public let startDate: String
    public let tokens: Int64

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = tokens
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let primaryLimit: RateLimitSnapshot
    public let otherLimits: [RateLimitSnapshot]
    public let dailyUsageBuckets: [DailyUsageBucket]
    public let lifetimeTokens: Int64?
    public let fetchedAt: Date

    public init(
        primaryLimit: RateLimitSnapshot,
        otherLimits: [RateLimitSnapshot] = [],
        dailyUsageBuckets: [DailyUsageBucket],
        lifetimeTokens: Int64?,
        fetchedAt: Date
    ) {
        self.primaryLimit = primaryLimit
        self.otherLimits = otherLimits
        self.dailyUsageBuckets = dailyUsageBuckets
        self.lifetimeTokens = lifetimeTokens
        self.fetchedAt = fetchedAt
    }
}

public struct UsageStatistics: Equatable, Sendable {
    public let sevenDayTotal: Int64
    public let sevenDayAverage: Int64
    public let thirtyDayTotal: Int64
    public let thirtyDayAverage: Int64

    public init(sevenDayTotal: Int64, sevenDayAverage: Int64, thirtyDayTotal: Int64, thirtyDayAverage: Int64) {
        self.sevenDayTotal = sevenDayTotal
        self.sevenDayAverage = sevenDayAverage
        self.thirtyDayTotal = thirtyDayTotal
        self.thirtyDayAverage = thirtyDayAverage
    }

    public static func calculate(
        buckets: [DailyUsageBucket],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageStatistics {
        let totalsByDate = Dictionary(grouping: buckets, by: \.startDate)
            .mapValues { entries in entries.reduce(Int64(0)) { $0 + $1.tokens } }

        func total(for dayCount: Int) -> Int64 {
            let today = calendar.startOfDay(for: now)
            return (1...dayCount).reduce(Int64(0)) { partial, offset in
                guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return partial }
                return partial + (totalsByDate[Self.dateKey(date, calendar: calendar)] ?? 0)
            }
        }

        let seven = total(for: 7)
        let thirty = total(for: 30)
        return UsageStatistics(
            sevenDayTotal: seven,
            sevenDayAverage: seven / 7,
            thirtyDayTotal: thirty,
            thirtyDayAverage: thirty / 30
        )
    }

    private static func dateKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
