import Foundation

public struct ReconciledSpend: Equatable, Sendable {
    public let totalCents: Int
    public let autoCents: Int
    public let apiCents: Int

    public init(totalCents: Int, autoCents: Int, apiCents: Int) {
        self.totalCents = totalCents
        self.autoCents = autoCents
        self.apiCents = apiCents
    }
}

/// On the billing-cycle start day the summary's included usage is the
/// authoritative spend. Scale the event split so Auto + API still equals that
/// total. With no events, keep a zero split instead of a total the pool bars
/// cannot explain.
public enum CycleStartSpend {
    public static func reconcile(
        autoCents: Int,
        apiCents: Int,
        includedUsedCents: Int
    ) -> ReconciledSpend {
        let included = max(includedUsedCents, 0)
        let auto = max(autoCents, 0)
        let api = max(apiCents, 0)
        let split = auto + api
        guard split > 0, included > 0 else {
            return ReconciledSpend(totalCents: 0, autoCents: 0, apiCents: 0)
        }
        if split == included {
            return ReconciledSpend(totalCents: included, autoCents: auto, apiCents: api)
        }
        let scaledAuto = min(
            max(Int((Double(auto) * Double(included) / Double(split)).rounded()), 0),
            included
        )
        return ReconciledSpend(
            totalCents: included,
            autoCents: scaledAuto,
            apiCents: included - scaledAuto
        )
    }
}
