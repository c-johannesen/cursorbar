import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var refreshTimer: Timer?

    init() {
        startAutoRefresh()
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            summary = try await CursorAPI.fetchUsageSummary()
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var menuBarLabel: String {
        if errorMessage != nil, summary == nil {
            return "!"
        }
        guard let includedPercentUsed else {
            return isLoading ? "…" : "!"
        }
        return "\(Int(includedPercentUsed.rounded()))%"
    }

    var statusColor: Color {
        if hasOverspend {
            return .red
        }
        guard let includedPercentUsed else {
            return .secondary
        }
        if includedPercentUsed >= 90 {
            return .red
        }
        if includedPercentUsed >= 70 {
            return .yellow
        }
        return .green
    }

    var planDisplayName: String {
        summary?.membershipType.capitalized ?? "Unknown"
    }

    var rawPercentUsed: Double? {
        summary?.individualUsage.plan.totalPercentUsed
    }

    /// Included pool usage, capped at 100%.
    var includedPercentUsed: Double? {
        guard let rawPercentUsed else { return nil }
        return min(rawPercentUsed, 100)
    }

    var totalCreditsCents: Int? {
        summary?.individualUsage.plan.breakdown.total
    }

    var rawUsedCreditsCents: Int? {
        guard let summary else { return nil }
        let total = Double(summary.individualUsage.plan.breakdown.total)
        let percent = summary.individualUsage.plan.totalPercentUsed
        return Int((total * percent / 100.0).rounded())
    }

    /// Amount consumed from the included + bonus pool only.
    var includedUsedCreditsCents: Int? {
        guard let rawUsedCreditsCents, let totalCreditsCents else { return nil }
        return min(rawUsedCreditsCents, totalCreditsCents)
    }

    var includedRemainingCreditsCents: Int? {
        guard let totalCreditsCents, let includedUsedCreditsCents else { return nil }
        return max(totalCreditsCents - includedUsedCreditsCents, 0)
    }

    var onDemandEnabled: Bool {
        summary?.individualUsage.onDemand.enabled ?? false
    }

    var onDemandUsedCents: Int {
        summary?.individualUsage.onDemand.used ?? 0
    }

    var onDemandLimitCents: Int? {
        summary?.individualUsage.onDemand.limit
    }

    var onDemandRemainingCents: Int? {
        summary?.individualUsage.onDemand.remaining
    }

    /// Usage beyond the included + bonus credit pool.
    var includedOverageCents: Int {
        guard let rawUsedCreditsCents, let totalCreditsCents else { return 0 }
        return max(rawUsedCreditsCents - totalCreditsCents, 0)
    }

    var overspendCents: Int {
        includedOverageCents + (onDemandEnabled ? onDemandUsedCents : 0)
    }

    var hasOverspend: Bool {
        overspendCents > 0
    }

    var billingCycleEndDate: Date? {
        guard let end = summary?.billingCycleEnd else { return nil }
        return Self.iso8601Formatter.date(from: end)
    }

    var billingCycleStartDate: Date? {
        guard let start = summary?.billingCycleStart else { return nil }
        return Self.iso8601Formatter.date(from: start)
    }

    var daysUntilReset: Int? {
        guard let billingCycleEndDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: billingCycleEndDate).day ?? 0
        return max(days, 0)
    }

    var billingCycleText: String {
        guard let start = billingCycleStartDate, let end = billingCycleEndDate else {
            return "Billing cycle unavailable"
        }
        let formatter = Self.shortDateFormatter
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    var lastUpdatedText: String {
        guard let lastUpdated else { return "Never" }
        return Self.timeFormatter.string(from: lastUpdated)
    }

    static func formatDollars(cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        return currencyFormatter.string(from: NSNumber(value: dollars)) ?? String(format: "$%.2f", dollars)
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()
}
