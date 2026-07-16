import AppKit
import Foundation
import UserNotifications

public enum QuotaNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

public struct QuotaNotificationContent: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

public enum QuotaNotificationEvent: Equatable, Sendable {
    case reset(currentRemaining: Int, nextResetAt: Int64, sevenDayTokens: Int64)
    case lowQuota(currentRemaining: Int, resetAt: Int64)

    public func content(timeZone: TimeZone = .current) -> QuotaNotificationContent {
        switch self {
        case .reset(let remaining, let resetAt, let tokens):
            return QuotaNotificationContent(
                identifier: "quota-reset-\(resetAt)",
                title: "Codex 周额度已重置",
                body: "当前剩余 \(remaining)% · 下次重置 \(Self.format(resetAt, timeZone: timeZone)) · 过去 7 天 \(TokenFormatter.compact(tokens)) tokens"
            )
        case .lowQuota(let remaining, let resetAt):
            return QuotaNotificationContent(
                identifier: "quota-low-\(resetAt)",
                title: "Codex 周额度仅剩 20%",
                body: "当前剩余 \(remaining)% · 预计 \(Self.format(resetAt, timeZone: timeZone)) 重置"
            )
        }
    }

    private static func format(_ timestamp: Int64, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

public protocol QuotaNotificationManaging: AnyObject {
    func authorizationStatus() async -> QuotaNotificationAuthorizationStatus
    func requestAuthorization() async -> QuotaNotificationAuthorizationStatus
    func deliver(_ event: QuotaNotificationEvent) async throws
}

public final class SystemQuotaNotificationManager: NSObject, QuotaNotificationManaging, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    public override convenience init() {
        self.init(center: .current())
    }

    init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
    }

    public func authorizationStatus() async -> QuotaNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    public func requestAuthorization() async -> QuotaNotificationAuthorizationStatus {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            return await authorizationStatus()
        } catch {
            return .denied
        }
    }

    public func deliver(_ event: QuotaNotificationEvent) async throws {
        let presentation = event.content()
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.body = presentation.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: presentation.identifier, content: content, trigger: nil)
        try await center.add(request)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private static func map(_ status: UNAuthorizationStatus) -> QuotaNotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .notDetermined
        }
    }
}

public struct QuotaObservationState: Codable, Equatable, Sendable {
    public var lastRemainingPercent: Int
    public var lastResetsAt: Int64
    public var lowQuotaNotifiedResetsAt: Int64?

    public init(lastRemainingPercent: Int, lastResetsAt: Int64, lowQuotaNotifiedResetsAt: Int64? = nil) {
        self.lastRemainingPercent = lastRemainingPercent
        self.lastResetsAt = lastResetsAt
        self.lowQuotaNotifiedResetsAt = lowQuotaNotifiedResetsAt
    }
}

public protocol QuotaObservationStatePersisting: AnyObject {
    func load() -> QuotaObservationState?
    func save(_ state: QuotaObservationState)
}

public final class UserDefaultsQuotaObservationStore: QuotaObservationStatePersisting {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "quotaObservationState.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> QuotaObservationState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(QuotaObservationState.self, from: data)
    }

    public func save(_ state: QuotaObservationState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

public struct QuotaNotificationTracker {
    private let persistence: any QuotaObservationStatePersisting

    public init(persistence: any QuotaObservationStatePersisting) {
        self.persistence = persistence
    }

    public func observe(
        remainingPercent: Int,
        resetsAt: Int64?,
        sevenDayTokens: Int64
    ) -> QuotaNotificationEvent? {
        guard let resetsAt else { return nil }
        let remaining = min(100, max(0, remainingPercent))

        guard var previous = persistence.load() else {
            persistence.save(QuotaObservationState(
                lastRemainingPercent: remaining,
                lastResetsAt: resetsAt,
                lowQuotaNotifiedResetsAt: remaining <= 20 ? resetsAt : nil
            ))
            return nil
        }

        var event: QuotaNotificationEvent?
        if resetsAt > previous.lastResetsAt {
            event = .reset(currentRemaining: remaining, nextResetAt: resetsAt, sevenDayTokens: sevenDayTokens)
            previous.lastResetsAt = resetsAt
            previous.lowQuotaNotifiedResetsAt = remaining <= 20 ? resetsAt : nil
        } else if resetsAt == previous.lastResetsAt,
                  previous.lastRemainingPercent > 20,
                  remaining <= 20,
                  previous.lowQuotaNotifiedResetsAt != resetsAt {
            event = .lowQuota(currentRemaining: remaining, resetAt: resetsAt)
            previous.lowQuotaNotifiedResetsAt = resetsAt
        }

        previous.lastRemainingPercent = remaining
        persistence.save(previous)
        return event
    }
}
