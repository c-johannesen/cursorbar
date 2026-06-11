import AppKit
import SwiftUI

@main
enum CursorBarMain {
    static func main() {
        if CommandLine.arguments.contains("--status") {
            runStatusCommand()
            return
        }
        CursorBarApp.main()
    }

    static func runStatusCommand() {
        let group = DispatchGroup()
        group.enter()
        Task {
            defer { group.leave() }
            do {
                let summary = try await CursorAPI.fetchUsageSummary()
                let plan = summary.individualUsage.plan
                let onDemand = summary.individualUsage.onDemand
                let total = Double(plan.breakdown.total)
                let rawUsed = total * plan.totalPercentUsed / 100.0
                let overage = max(rawUsed - total, 0)
                let onDemandUsed = onDemand.enabled ? Double(onDemand.used) : 0
                let overspend = overage + onDemandUsed
                let percent = min(plan.totalPercentUsed, 100)
                if overspend > 0 {
                    print(String(format: "OK %.0f%% (overspend $%.2f)", percent, overspend / 100.0))
                } else {
                    print(String(format: "OK %.0f%%", percent))
                }
                exit(0)
            } catch {
                fputs("ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        group.wait()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct CursorBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()
    @StateObject private var updater = UpdateChecker()
    @StateObject private var agents = AgentMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store, updater: updater, agents: agents)
        } label: {
            MenuBarLabel(store: store, agents: agents)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MenuBarPrefs {
    static let showQuotaKey = "menuBarShowQuota"
    static let showDailyKey = "menuBarShowDaily"
    static let showOverspendKey = "menuBarShowOverspend"
    static let showAgentsKey = "menuBarShowAgents"
}

private struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var agents: AgentMonitor
    @AppStorage(MenuBarPrefs.showQuotaKey) private var showQuota = true
    @AppStorage(MenuBarPrefs.showDailyKey) private var showDaily = true
    @AppStorage(MenuBarPrefs.showOverspendKey) private var showOverspend = true
    @AppStorage(MenuBarPrefs.showAgentsKey) private var showAgents = true

    var body: some View {
        if store.summary == nil {
            Text(store.menuBarLabel)
                .monospacedDigit()
        } else if !hasVisibleContent {
            Image(systemName: "chart.bar.fill")
        } else if let image = renderedImage {
            Image(nsImage: image)
        } else {
            Text(store.menuBarLabel)
                .monospacedDigit()
        }
    }

    private var hasVisibleContent: Bool {
        showAgents || showQuota || showDaily || (showOverspend && store.hasOverspend)
    }

    private var renderedImage: NSImage? {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let content = HStack(spacing: 8) {
            if showAgents {
                MenuBarAgentBadge(
                    totalRunning: agents.totalRunning,
                    needsInputCount: agents.needsInputCount
                )
            }
            if showQuota {
                MenuBarRingGauge(
                    percent: store.includedPercentUsed,
                    fillColor: store.statusColor,
                    isDark: isDark
                )
            }
            if showDaily {
                MenuBarBarGauge(
                    percent: store.dailyUtilizationPercent,
                    fillColor: store.dailyStatusColor,
                    isDark: isDark
                )
            }
            if showOverspend, store.hasOverspend {
                Text(UsageStore.formatDollarsCompact(cents: store.overspendCents))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}

private struct MenuBarAgentBadge: View {
    let totalRunning: Int
    let needsInputCount: Int

    private var fillColor: Color {
        if needsInputCount > 0 { return .yellow }
        return totalRunning > 0 ? .green : .red
    }

    private var text: String {
        let count = needsInputCount > 0 ? needsInputCount : totalRunning
        return AgentMonitorFormatting.compactCount(count)
    }

    private var textColor: Color {
        needsInputCount > 0 ? .black : .white
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor.opacity(0.9))
            Text(text)
                .font(.system(size: text.count > 1 ? 9 : 10, weight: .bold, design: .monospaced))
                .foregroundStyle(textColor)
                .fixedSize()
        }
        .frame(width: 16, height: 16)
    }
}

private struct PieSlice: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return Path() }

        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * clamped),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct MenuBarRingGauge: View {
    private static let size: CGFloat = 16

    let percent: Double?
    let fillColor: Color
    let isDark: Bool

    private var trackColor: Color {
        isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.12)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(trackColor)

            if let percent {
                PieSlice(fraction: percent / 100.0)
                    .fill(fillColor.opacity(0.9))
            }
        }
        .frame(width: Self.size, height: Self.size)
    }
}

private struct MenuBarBarGauge: View {
    let percent: Double?
    let fillColor: Color
    let isDark: Bool

    private var textColor: Color {
        isDark ? .white : .black
    }

    private var trackColor: Color {
        isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.12)
    }

    private var valueText: String {
        guard let percent else { return "–" }
        return "\(Int(percent.rounded()))%"
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(trackColor)
                    if let percent {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(fillColor.opacity(0.85))
                            .frame(width: max(geometry.size.width * min(percent / 100.0, 1), percent > 0 ? 4 : 0))
                    }
                }
            }

            Text(valueText)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(textColor)
                .shadow(color: isDark ? .black.opacity(0.4) : .white.opacity(0.4), radius: 0.5)
        }
        .frame(width: 38, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct UsageMeterView: View {
    let title: String
    let percent: Double
    let color: Color
    var usedCents: Int?
    var limitCents: Int?
    var remainingCents: Int?
    var usedLabel: String = "Used"
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .frame(width: 96, alignment: .leading)
                    .lineLimit(1)

                ProgressView(value: min(max(percent / 100.0, 0), 1))
                    .tint(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 6)

                Text("\(Int(percent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(color)
                    .frame(width: 30, alignment: .trailing)
            }

            if let detailText = detailText {
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailText: String? {
        guard let usedCents, let limitCents else { return nil }

        var text = "\(usedLabel) \(UsageStore.formatDollars(cents: usedCents)) / \(UsageStore.formatDollars(cents: limitCents))"
        if let remainingCents {
            text += " · \(UsageStore.formatDollars(cents: remainingCents)) left"
        }
        return text
    }
}

private struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var agents: AgentMonitor
    @State private var showSettings = false
    @AppStorage(MenuBarPrefs.showQuotaKey) private var showQuota = true
    @AppStorage(MenuBarPrefs.showDailyKey) private var showDaily = true
    @AppStorage(MenuBarPrefs.showOverspendKey) private var showOverspend = true
    @AppStorage(MenuBarPrefs.showAgentsKey) private var showAgents = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            agentsSection
            Divider()

            if let errorMessage = store.errorMessage, store.summary == nil {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                usageSection
            }

            if updater.availableUpdate != nil || updater.statusMessage != nil {
                Divider()
                updateSection
            }

            if showSettings {
                Divider()
                settingsSection
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Show in menu bar")
                .font(.caption.weight(.medium))

            Toggle("Agents badge", isOn: $showAgents)
            Toggle("Quota gauge", isOn: $showQuota)
            Toggle("Daily utilization gauge", isOn: $showDaily)
            Toggle("Overspend amount", isOn: $showOverspend)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agents")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(agents.totalRunning) running")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(agents.totalRunning > 0 ? .green : .secondary)
            }

            HStack {
                Text("Local")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(agents.localRunningCount)")
                    .monospacedDigit()
            }
            .font(.caption)

            HStack {
                Text("Cloud")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(agents.cloudRunningCount)")
                    .monospacedDigit()
            }
            .font(.caption)

            if !agents.agentsNeedingInput.isEmpty {
                Text("Needs input")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.top, 2)

                ForEach(agents.agentsNeedingInput) { agent in
                    Button {
                        agent.openInCursor()
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(agent.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in Cursor")
                }
            }
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        if let update = updater.availableUpdate {
            HStack {
                Text("Update available: v\(update.version)")
                    .font(.caption)
                Spacer()
                Button(updater.isUpdating ? "Updating…" : "Update") {
                    Task { await updater.installUpdate() }
                }
                .disabled(updater.isUpdating)
            }
        }

        if let statusMessage = updater.statusMessage {
            Text(statusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CursorBar")
                    .font(.headline)
                Spacer()
                Text(store.planDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(store.billingCycleText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let daysUntilReset = store.daysUntilReset {
                Text("Resets in \(daysUntilReset) day\(daysUntilReset == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        let hasBillingMeters = store.includedPercentUsed != nil
            || store.autoPercentUsed != nil
            || store.apiPercentUsed != nil

        if hasBillingMeters {
            VStack(alignment: .leading, spacing: 10) {
                if let percentUsed = store.includedPercentUsed {
                    UsageMeterView(
                        title: "Included usage",
                        percent: percentUsed,
                        color: store.statusColor,
                        usedCents: store.includedUsedCreditsCents,
                        limitCents: store.totalCreditsCents,
                        remainingCents: store.includedRemainingCreditsCents
                    )
                }

                if let autoPercent = store.autoPercentUsed {
                    UsageMeterView(
                        title: "Auto / Composer",
                        percent: autoPercent,
                        color: store.autoStatusColor,
                        usedCents: store.autoUsedCreditsCents,
                        limitCents: store.autoLimitCreditsCents
                    )
                }

                if let apiPercent = store.apiPercentUsed {
                    UsageMeterView(
                        title: "API",
                        percent: apiPercent,
                        color: store.apiStatusColor,
                        usedCents: store.apiUsedCreditsCents,
                        limitCents: store.apiLimitCreditsCents
                    )
                }
            }
        }

        if hasBillingMeters, store.dailyUtilizationPercent != nil {
            Divider()
        }

        if let dailyPercent = store.dailyUtilizationPercent {
            UsageMeterView(
                title: "Daily utilization",
                percent: dailyPercent,
                color: store.dailyStatusColor,
                usedCents: store.todaySpendCents,
                limitCents: store.dailyBudgetCents,
                usedLabel: "Today",
                footnote: store.workingDaysInCycle.map { "Daily budget = quota / \($0) working days" }
            )
        }

        if store.hasOverspend {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Overspend")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(UsageStore.formatDollars(cents: store.overspendCents))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }

                if store.includedOverageCents > 0 {
                    HStack {
                        Text("Over included")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageStore.formatDollars(cents: store.includedOverageCents))
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                    .font(.caption)
                }

                if store.onDemandEnabled, store.onDemandUsedCents > 0 {
                    HStack {
                        Text("On-demand")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageStore.formatDollars(cents: store.onDemandUsedCents))
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                    .font(.caption)
                }
            }
        }

        if store.onDemandEnabled {
            VStack(alignment: .leading, spacing: 6) {
                if !store.hasOverspend {
                    HStack {
                        Text("On-demand spend")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if let limit = store.onDemandLimitCents {
                            Text("\(UsageStore.formatDollars(cents: store.onDemandUsedCents)) / \(UsageStore.formatDollars(cents: limit))")
                                .monospacedDigit()
                        } else {
                            Text(UsageStore.formatDollars(cents: store.onDemandUsedCents))
                                .monospacedDigit()
                        }
                    }
                }

                if let limit = store.onDemandLimitCents {
                    HStack {
                        Text(store.hasOverspend ? "On-demand budget" : "On-demand limit")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageStore.formatDollars(cents: limit))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }

                if let remaining = store.onDemandRemainingCents {
                    HStack {
                        Text("On-demand remaining")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageStore.formatDollars(cents: remaining))
                            .monospacedDigit()
                            .foregroundStyle(remaining == 0 ? .red : .primary)
                    }
                    .font(.caption)
                }
            }
        }

        if let errorMessage = store.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Text("Updated \(store.lastUpdatedText) · v\(UpdateChecker.currentVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Menu bar settings")

            Button {
                Task { await updater.checkForUpdates(announceResult: true) }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .help("Check for updates")
            .disabled(updater.isChecking || updater.isUpdating)

            Button("Refresh") {
                Task { await store.refresh() }
            }
            .disabled(store.isLoading)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
