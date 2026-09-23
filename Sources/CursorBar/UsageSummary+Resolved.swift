import Foundation

enum UsageCredits {
    /// Guaranteed minimum included credits for Cursor Models on individual plans ($200).
    static let minimumCursorModelsIncludedCents = 20_000
    /// Guaranteed minimum included credits for Other Models on individual plans ($400).
    static let minimumOtherModelsIncludedCents = 40_000
    /// Floor for the included pool when an individual plan reports no usage yet.
    static let minimumIncludedCreditsCents = minimumCursorModelsIncludedCents + minimumOtherModelsIncludedCents
}

extension UsageSummary {
    var isUnlimitedPlan: Bool { isUnlimited ?? false }

    var hasDisplayableUsage: Bool {
        isUnlimitedPlan
            || includedPercentUsed != nil
            || cursorModelsPercentUsed != nil
            || otherModelsPercentUsed != nil
            || includedUsedCents != nil
    }

    var resolvedMembershipType: String {
        let raw = membershipType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "unknown" : raw
    }

    var plan: PlanUsage? { individualUsage?.plan }
    var overall: OverallUsage? { individualUsage?.overall }

    var resolvedOnDemand: OnDemandUsage? {
        individualUsage?.onDemand ?? teamUsage?.onDemand
    }

    /// Pro / Ultra style $200+$400 floors. Never applied to Enterprise or team-billed seats.
    var appliesIndividualCreditFloors: Bool {
        if limitType?.lowercased() == "team" { return false }
        switch resolvedMembershipType.lowercased() {
        case "enterprise", "team", "business":
            return false
        default:
            return true
        }
    }

    /// Cursor Models pool (Auto, Composer, Cursor Grok). `autoPercentUsed` on the wire.
    /// The display-message fallback only applies when there's no `overall` (Enterprise/team
    /// aggregate) usage either: on those contracts the message is generic boilerplate
    /// ("You've used 0% of your included total usage") rather than a real per-pool figure.
    var cursorModelsPercentUsed: Double? {
        if isUnlimitedPlan { return nil }
        if let auto = plan?.autoPercentUsed { return auto }
        guard overall == nil else { return nil }
        return Self.percent(fromDisplayMessage: autoModelSelectedDisplayMessage)
    }

    /// Other Models pool (named / third-party). `apiPercentUsed` on the wire. See
    /// `cursorModelsPercentUsed` for why the display-message fallback is skipped when
    /// `overall` usage is present.
    var otherModelsPercentUsed: Double? {
        if isUnlimitedPlan { return nil }
        if let api = plan?.apiPercentUsed { return api }
        guard overall == nil else { return nil }
        return Self.percent(fromDisplayMessage: namedModelSelectedDisplayMessage)
    }

    /// Blended included-usage percentage. Prefers `totalPercentUsed`, and falls back to
    /// `overall.used / overall.limit` on Enterprise/team contracts that omit `plan` entirely
    /// (and so never populate `totalPercentUsed`) but do report an aggregate `overall` figure.
    var includedPercentUsed: Double? {
        if isUnlimitedPlan { return nil }
        if let total = plan?.totalPercentUsed { return total }
        if let used = overall?.used, let limit = overall?.limit, limit > 0 {
            return Double(used) / Double(limit) * 100.0
        }
        return nil
    }

    /// Amount used against the included pool. Prefer `breakdown.total` over `plan.used`:
    /// on some Enterprise payloads `plan.used` is the Other Models cap, not included spend.
    var includedUsedCents: Int? {
        if let total = plan?.breakdown?.total { return total }
        if let overallUsed = overall?.used { return overallUsed }
        return nil
    }

    var includedLimitCents: Int? {
        if let overallLimit = overall?.limit, overallLimit > 0 {
            return overallLimit
        }

        let percent = includedPercentUsed ?? 0
        if let used = includedUsedCents {
            let derived = percent > 0 ? Int((Double(used) / (percent / 100.0)).rounded()) : 0
            if appliesIndividualCreditFloors {
                return max(derived, UsageCredits.minimumIncludedCreditsCents)
            }
            return derived > 0 ? derived : nil
        }

        return appliesIndividualCreditFloors ? UsageCredits.minimumIncludedCreditsCents : nil
    }

    /// Other Models dollar cap from `plan.limit`. Nil when the plan is disabled or has no limit.
    /// Cursor Models has no corresponding limit field — never invent one from included − Other Models.
    var otherModelsLimitCents: Int? {
        guard plan?.enabled != false else { return nil }
        guard let limit = plan?.limit, limit > 0 else { return nil }
        return limit
    }

    var otherModelsUsedCents: Int? {
        guard let limit = otherModelsLimitCents, let percent = otherModelsPercentUsed else { return nil }
        return Int((Double(limit) * percent / 100.0).rounded())
    }

    /// Leading `N` or `N.N` before `%` in Cursor's prose, e.g. "You've used 8% of your included total usage".
    static func percent(fromDisplayMessage message: String?) -> Double? {
        guard let message, let match = message.firstMatch(of: /(\d+(?:\.\d+)?)\s*%/) else { return nil }
        return Double(match.1)
    }
}
