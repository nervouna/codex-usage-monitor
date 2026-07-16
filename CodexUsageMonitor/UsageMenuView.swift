import SwiftUI

struct UsageMenuView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            quotaHeader

            if let error = store.errorMessage {
                errorBanner(error)
            }

            Divider()
            usageSection

            if let snapshot = store.snapshot, !snapshot.otherLimits.isEmpty {
                Divider()
                otherLimitsSection(snapshot.otherLimits)
            }

            Divider()
            footer
        }
        .padding(18)
        .frame(width: 360)
        .onAppear {
            store.start()
            Task { await store.handlePopoverOpened() }
        }
    }

    private var quotaHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 本周额度")
                        .font(.headline)
                    Text("7 天滚动窗口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let remaining = store.snapshot?.primaryLimit.remainingPercent {
                    Text("\(remaining)%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("剩余")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.isRefreshing ? "读取中…" : "暂无数据")
                        .foregroundStyle(.secondary)
                }
            }

            if let remaining = store.snapshot?.primaryLimit.remainingPercent {
                ProgressView(value: Double(remaining), total: 100)
                    .tint(color(for: remaining))
                if let resetDate = store.snapshot?.primaryLimit.resetDate {
                    Text("重置时间：\(resetDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token 用量")
                .font(.headline)
            metricRow(
                title: "过去 7 天",
                total: store.statistics.sevenDayTotal,
                average: store.statistics.sevenDayAverage
            )
            metricRow(
                title: "过去 30 天",
                total: store.statistics.thirtyDayTotal,
                average: store.statistics.thirtyDayAverage
            )
            HStack {
                Text("历史总计")
                Spacer()
                tokenValue(store.snapshot?.lifetimeTokens)
            }
        }
    }

    private func metricRow(title: String, total: Int64, average: Int64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                tokenValue(store.snapshot == nil ? nil : total)
                Text(store.snapshot == nil ? "日均 --" : "日均 \(TokenFormatter.compact(average))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tokenValue(_ value: Int64?) -> some View {
        Group {
            if let value {
                Text(TokenFormatter.compact(value))
                    .help("\(TokenFormatter.exact(value)) tokens")
            } else {
                Text("--")
                    .foregroundStyle(.secondary)
            }
        }
        .fontWeight(.medium)
    }

    private func otherLimitsSection(_ limits: [RateLimitSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("其他模型额度")
                .font(.headline)
            ForEach(limits) { limit in
                HStack {
                    Text(limit.displayName)
                        .lineLimit(1)
                    Spacer()
                    Text(limit.remainingPercent.map { "\($0)% 剩余" } ?? "--")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: store.isStale ? "exclamationmark.arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                if store.isStale {
                    Text("数据可能已过期")
                        .fontWeight(.medium)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("额度通知", isOn: Binding(
                    get: { store.notificationsEnabled },
                    set: { store.setNotificationsEnabled($0) }
                ))

                if store.notificationsEnabled && store.notificationAuthorizationStatus == .denied {
                    HStack {
                        Text("通知权限未开启")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开系统设置") { store.openNotificationSettings() }
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                }

                if let notificationError = store.notificationErrorMessage {
                    Text(notificationError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Toggle("开机时启动", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))

            HStack {
                if let date = store.snapshot?.fetchedAt {
                    Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)

                Button("退出") { store.quit() }
            }
        }
    }

    private func color(for remaining: Int) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 30 { return .orange }
        return .accentColor
    }
}

enum TokenFormatter {
    static func compact(_ value: Int64) -> String {
        let number = Double(value)
        if value >= 100_000_000 { return String(format: "%.2f 亿", number / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f 万", number / 10_000) }
        return exact(value)
    }

    static func exact(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
