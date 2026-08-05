import SwiftUI

/// Persistent, actionable banner for conditions the user has to resolve (spec §4.6, §12).
///
/// Deliberately not an alert: an automation denial reproduces on every single poll, and a
/// modal per poll would make the app unusable. This sits in the layout until the
/// condition clears on its own.
struct StatusBanner: View {
    let failure: NowPlayingFailure
    let sourceName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if case .automationDenied = failure {
                Button("Open Settings…") { NowPlayingMonitor.openAutomationSettings() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.35)))
    }

    private var icon: String {
        switch failure {
        case .automationDenied: "lock.trianglebadge.exclamationmark"
        case .providerError: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch failure {
        case .automationDenied: "Turntable can't read \(sourceName)"
        case .providerError: "\(sourceName) isn't responding"
        }
    }

    private var detail: String {
        switch failure {
        case .automationDenied:
            "Allow Turntable to control \(sourceName) in Privacy & Security ▸ Automation."
        case let .providerError(code, message):
            "\(message) (\(code))"
        }
    }
}
