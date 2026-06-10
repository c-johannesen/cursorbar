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
                let percent = summary.individualUsage.plan.totalPercentUsed
                print(String(format: "OK %.0f%%", percent))
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

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Text(store.menuBarLabel)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if let errorMessage = store.errorMessage, store.summary == nil {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                usageSection
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
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
        if let percentUsed = store.percentUsed {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Included usage")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(percentUsed.rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(store.statusColor)
                }

                ProgressView(value: min(max(percentUsed / 100.0, 0), 1))
                    .tint(store.statusColor)

                if let used = store.usedCreditsCents,
                   let total = store.totalCreditsCents,
                   let remaining = store.remainingCreditsCents
                {
                    HStack {
                        Text("Used")
                        Spacer()
                        Text("\(UsageStore.formatDollars(cents: used)) / \(UsageStore.formatDollars(cents: total))")
                            .monospacedDigit()
                    }
                    .font(.caption)

                    HStack {
                        Text("Remaining")
                        Spacer()
                        Text(UsageStore.formatDollars(cents: remaining))
                            .monospacedDigit()
                            .foregroundStyle(remaining == 0 ? .red : .primary)
                    }
                    .font(.caption)
                }
            }
        }

        if store.onDemandEnabled {
            HStack {
                Text("On-demand spend")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(UsageStore.formatDollars(cents: store.onDemandUsedCents))
                    .monospacedDigit()
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
            Text("Updated \(store.lastUpdatedText)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

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
