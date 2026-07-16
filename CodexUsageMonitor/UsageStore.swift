import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var statistics = UsageStatistics(
        sevenDayTotal: 0,
        sevenDayAverage: 0,
        thirtyDayTotal: 0,
        thirtyDayAverage: 0
    )
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isStale = false
    @Published public private(set) var launchAtLogin: Bool
    @Published public private(set) var notificationsEnabled: Bool
    @Published public private(set) var notificationAuthorizationStatus: QuotaNotificationAuthorizationStatus = .notDetermined
    @Published public private(set) var notificationErrorMessage: String?

    private let fetcher: any UsageFetching
    private let now: @Sendable () -> Date
    private let notificationManager: any QuotaNotificationManaging
    private let notificationTracker: QuotaNotificationTracker
    private let preferences: UserDefaults
    private var refreshLoop: Task<Void, Never>?

    private static let notificationsEnabledKey = "quotaNotificationsEnabled"
    private static let notificationPromptedKey = "quotaNotificationPermissionPrompted"

    public init(
        fetcher: any UsageFetching = CodexAppServerClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        notificationManager: any QuotaNotificationManaging = SystemQuotaNotificationManager(),
        observationPersistence: (any QuotaObservationStatePersisting)? = nil,
        preferences: UserDefaults = .standard
    ) {
        self.fetcher = fetcher
        self.now = now
        self.notificationManager = notificationManager
        self.preferences = preferences
        self.notificationTracker = QuotaNotificationTracker(
            persistence: observationPersistence ?? UserDefaultsQuotaObservationStore(defaults: preferences)
        )
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.notificationsEnabled = preferences.object(forKey: Self.notificationsEnabledKey) as? Bool ?? true
    }

    deinit { refreshLoop?.cancel() }

    public var menuBarTitle: String {
        if let remaining = snapshot?.primaryLimit.remainingPercent { return "\(remaining)%" }
        return isRefreshing ? "…" : "--%"
    }

    public var menuBarSymbol: String {
        guard let remaining = snapshot?.primaryLimit.remainingPercent else { return "gauge.with.dots.needle.33percent" }
        if remaining <= 10 { return "exclamationmark.triangle.fill" }
        if remaining <= 30 { return "gauge.with.dots.needle.33percent" }
        return "gauge.with.dots.needle.67percent"
    }

    public func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private func refreshIfStale() {
        guard !isRefreshing else { return }
        guard let fetchedAt = snapshot?.fetchedAt else {
            Task { await refresh() }
            return
        }
        if now().timeIntervalSince(fetchedAt) >= 60 {
            Task { await refresh() }
        }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await fetcher.fetchSnapshot()
            let newStatistics = UsageStatistics.calculate(buckets: newSnapshot.dailyUsageBuckets, now: now())
            let notificationEvent = notificationTracker.observe(
                remainingPercent: newSnapshot.primaryLimit.remainingPercent ?? 0,
                resetsAt: newSnapshot.primaryLimit.primary?.resetsAt,
                sevenDayTokens: newStatistics.sevenDayTotal
            )
            snapshot = newSnapshot
            statistics = newStatistics
            errorMessage = nil
            isStale = false
            if let notificationEvent {
                await deliverNotificationIfAllowed(notificationEvent)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isStale = snapshot != nil
        }
    }

    public func handlePopoverOpened() async {
        refreshIfStale()
        notificationAuthorizationStatus = await notificationManager.authorizationStatus()
        guard notificationsEnabled,
              !preferences.bool(forKey: Self.notificationPromptedKey) else { return }

        preferences.set(true, forKey: Self.notificationPromptedKey)
        if notificationAuthorizationStatus == .notDetermined {
            notificationAuthorizationStatus = await notificationManager.requestAuthorization()
        }
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        preferences.set(enabled, forKey: Self.notificationsEnabledKey)
        notificationErrorMessage = nil
        guard enabled else { return }

        Task {
            notificationAuthorizationStatus = await notificationManager.authorizationStatus()
            if notificationAuthorizationStatus == .notDetermined {
                preferences.set(true, forKey: Self.notificationPromptedKey)
                notificationAuthorizationStatus = await notificationManager.requestAuthorization()
            }
        }
    }

    public func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func deliverNotificationIfAllowed(_ event: QuotaNotificationEvent) async {
        guard notificationsEnabled else { return }
        notificationAuthorizationStatus = await notificationManager.authorizationStatus()
        guard notificationAuthorizationStatus == .authorized else { return }
        do {
            try await notificationManager.deliver(event)
            notificationErrorMessage = nil
        } catch {
            notificationErrorMessage = "通知发送失败：\(error.localizedDescription)"
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = "无法更新开机启动：\(error.localizedDescription)"
        }
    }

    public func quit() {
        NSApplication.shared.terminate(nil)
    }
}
