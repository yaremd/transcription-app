import SwiftUI

/// The one upgrade surface in the app, opened only on user intent: tapping a
/// locked control, or the License pane's buttons. No nags, no urgency theater
/// — the free column is real and the sheet says so.
struct UpgradeSheet: View {
    /// What the user tapped to get here, if anything — shown first.
    var highlighted: ProFeature?

    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.dismiss) private var dismiss

    @State private var enteringKey = false
    @State private var key = ""
    @State private var activating = false
    @State private var activationError: String?

    private let client: LicenseActivating = PolarLicenseClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)
            ThemeDivider()
            featureList
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            ThemeDivider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
        .frame(width: 460)
        .background(Theme.background)
        .onAppear { entitlements.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Seal Pro")
                    .font(Theme.pageTitle)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Text(headerLine)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerLine: String {
        switch entitlements.entitlement {
        case .free:
            return "Everything you use today stays free — unlimited meetings, full-accuracy transcription, notes, search, and export. Pro adds the professional finish."
        case .trial:
            return "You're trying everything Seal Pro does. Keep it with a license that's yours forever — no subscription."
        case .pro, .lifetime:
            return "This Mac has Seal Pro. Thank you for backing an app that never phones home."
        }
    }

    // MARK: - Features

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(orderedFeatures) { feature in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: feature == highlighted ? "sparkle" : "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(feature == highlighted ? Theme.amber : Theme.accent)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.displayName)
                            .font(Theme.bodyMedium)
                        Text(feature.blurb)
                            .font(Theme.sub)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The tapped feature leads; the rest follow in canonical order.
    private var orderedFeatures: [ProFeature] {
        guard let highlighted else { return ProFeature.allCases }
        return [highlighted] + ProFeature.allCases.filter { $0 != highlighted }
    }

    // MARK: - Footer (price + actions per state)

    @ViewBuilder
    private var footer: some View {
        switch entitlements.entitlement {
        case .pro, .lifetime:
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.linearPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        case .free, .trial:
            VStack(alignment: .leading, spacing: 14) {
                priceRow
                if let days = entitlements.trialDaysLeft {
                    Text("Pro trial — \(days) day\(days == 1 ? "" : "s") left. Everything you make is yours either way.")
                        .font(Theme.sub)
                        .foregroundStyle(.secondary)
                }
                if enteringKey { keyEntry }
                actions
                Text("One license, two Macs. Checked once at activation — Seal never phones home.")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var priceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Pricing.earlyBird)
                        .font(.system(size: 22, weight: .semibold))
                    Text(Pricing.regular)
                        .font(Theme.body)
                        .strikethrough()
                        .foregroundStyle(.tertiary)
                    Text("early-bird")
                        .font(Theme.meta)
                        .foregroundStyle(.secondary)
                }
                Text("Yours forever · includes 1 year of updates · \(Pricing.renewal)/yr after, only if you want more")
                    .font(Theme.sub)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Pricing.lifetime)
                    .font(Theme.title)
                Text("lifetime updates")
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Straight to checkout once the storefront is live; the pricing page
    /// (which also sells Lifetime) until then.
    private var buyURL: URL { SealStore.checkoutPro ?? Pricing.pricingURL }

    private var actions: some View {
        HStack(spacing: 8) {
            if entitlements.trialAvailable {
                Button("Start \(Pricing.trialDays)-day free trial") {
                    entitlements.startTrial()
                    dismiss()
                }
                .buttonStyle(.linearPrimary)
                .keyboardShortcut(.defaultAction)
                Button("Buy Seal Pro") { NSWorkspace.shared.open(buyURL) }
                    .buttonStyle(.linearQuiet)
            } else {
                Button("Buy Seal Pro") { NSWorkspace.shared.open(buyURL) }
                    .buttonStyle(.linearPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
            Button(enteringKey ? "Hide key entry" : "Enter license key") {
                withAnimation(.easeOut(duration: 0.15)) { enteringKey.toggle() }
            }
            .buttonStyle(.linearQuiet)
        }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Paste your license key", text: $key)
                    .linearField()
                    .onSubmit(activate)
                Button(activating ? "Activating…" : "Activate") { activate() }
                    .buttonStyle(.linearPrimaryCompact)
                    .disabled(activating || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let activationError {
                Text(activationError)
                    .font(Theme.sub)
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activate() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !activating else { return }
        activating = true
        activationError = nil
        Task { @MainActor in
            defer { activating = false }
            do {
                let record = try await client.activate(key: trimmed)
                entitlements.apply(license: record)
                dismiss()
            } catch {
                activationError = (error as? LicenseError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
