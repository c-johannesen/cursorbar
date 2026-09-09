import Foundation

public enum PaceCalculator {
    /// End bound so “today” counts when used as `workingDays` endExclusive from cycle start.
    public static func elapsedEndExclusive(
        now: Date,
        cycleEnd: Date,
        calendar: Calendar = .current
    ) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let cycleEndStart = calendar.startOfDay(for: cycleEnd)
        return min(tomorrow, cycleEndStart)
    }

    /// Count Mon–Fri days in half-open interval `[start, endExclusive)`.
    public static func workingDays(
        from start: Date,
        to endExclusive: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard start < endExclusive else { return 0 }
        var count = 0
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: endExclusive)
        while day < lastDay {
            if !calendar.isDateInWeekend(day) {
                count += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return count
    }

    /// Future workdays after today through cycle end: `[tomorrow, cycleEnd)`.
    /// Today is excluded so today’s spend is not also reserved in remaining workdays.
    public static func remainingWorkdays(
        now: Date,
        cycleEnd: Date,
        calendar: Calendar = .current
    ) -> Int {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let cycleEndStart = calendar.startOfDay(for: cycleEnd)
        return workingDays(from: tomorrow, to: cycleEndStart, calendar: calendar)
    }

    /// Redistributed allowance across future workdays (`remaining ÷ remainingWorkdays`).
    public static func dailyBudgetCents(remainingCents: Int, remainingWorkdays: Int) -> Int? {
        guard remainingCents >= 0 else { return nil }
        let days = max(remainingWorkdays, 1)
        return remainingCents / days  // may be 0 when remaining is 0
    }

    /// Mean burn per elapsed workday so far.
    public static func avgDailyCents(usedCents: Int, elapsedWorkdays: Int) -> Int? {
        guard usedCents >= 0 else { return nil }
        let days = max(elapsedWorkdays, 1)
        return usedCents / days
    }

    /// Avg burn vs today’s redistributed budget. 100 = on track for remaining days.
    public static func dailyUtilizationPercent(avgDailyCents: Int, dailyBudgetCents: Int) -> Double? {
        guard dailyBudgetCents > 0 else { return nil }
        return Double(avgDailyCents) / Double(dailyBudgetCents) * 100.0
    }

    /// Today spend vs redistributed budget. Missing spend counts as $0 so a quiet
    /// morning still shows 0% instead of hiding the daily meters.
    public static func dailyUtilizationPercent(spendCents: Int?, dailyBudgetCents: Int?) -> Double? {
        guard let dailyBudgetCents else { return nil }
        return dailyUtilizationPercent(avgDailyCents: spendCents ?? 0, dailyBudgetCents: dailyBudgetCents)
    }
}

/// Pixel width of the colored fill inside a fixed menu-bar gauge. 0% keeps a
/// full track (width 0 fill) so ImageRenderer still has a laid-out bar.
public enum MenuBarBarFill {
    public static func width(percent: Double?, in totalWidth: Double, minimumFilled: Double = 4) -> Double {
        guard let percent, percent > 0, totalWidth > 0 else { return 0 }
        return max(totalWidth * min(percent / 100.0, 1), minimumFilled)
    }
}
