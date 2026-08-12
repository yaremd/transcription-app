import SwiftUI

/// The one upgrade surface in the app, opened only on user intent: tapping a
/// locked control, or the License pane's buttons. No nags, no urgency theater
/// — the free column is real and the sheet says so.
///
/// Structure is a pitch, not a spec sheet: a hero headline that sells the
/// outcome (and becomes the tapped feature's own line when there is one), an
/// icon grid a reader can scan in one pass, the three honest differentiators
/// (pay once · on your Mac · free stays free), then a single commit zone.
struct UpgradeSheet: View {
    /// What the user tapped to get here, if anything — it becomes the headline.
    var highlighted: ProFeature?

    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var enteringKey = false
    @State private var key = ""
    @State private var activating = false
    @State private var activationError: String?
    @State private var appeared = false
    /// A key was just activated in this sheet — show the success moment
    /// instead of silently closing on the person who just paid.
    @State private var justActivated = false
    @State private var sealPop = false

    private let client: LicenseActivating = FreemiusLicenseClient()

    var body: some View {
        Group {
            if justActivated {
                successView
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    ThemeDivider()
                    featureGrid
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                    ThemeDivider()
                    footer
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                }
            }
        }
        .frame(width: 560)
        .background(Theme.background)
        .onAppear {
            entitlements.refresh()
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 1.0)) { appeared = true }
            }
        }
    }

    // MARK: - Success (after a key activates)

    /// The completion moment: the seal lands, the plan is stated plainly, one
    /// button back to work. Bounce is reserved for exactly this — the one
    /// earned celebration in the app — and dropped under Reduce Motion.
    private var successView: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .scaleEffect(sealPop ? 1 : 0.6)
            .opacity(sealPop ? 1 : 0)
            .padding(.bottom, 10)

            Text("Welcome to Seal Pro.")
                .font(.system(size: 25, weight: .semibold))
                .tracking(-0.4)
            Text(successLine)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            Button("Start using Pro") { dismiss() }
                .buttonStyle(.linearPrimary)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 16)

            Text("Manage it anytime in Settings → License. One license, two Macs.")
                .font(Theme.meta)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 44)
        .onAppear {
            if reduceMotion {
                sealPop = true
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { sealPop = true }
            }
        }
    }

    private var successLine: String {
        switch entitlements.entitlement {
        case .lifetime:
            return "Lifetime updates, licensed on this Mac. Thank you for backing an app that never phones home."
        case .pro(let updatesThrough):
            return "Licensed on this Mac, with updates through \(updatesThrough.formatted(date: .abbreviated, time: .omitted)). Every Pro feature runs on your Mac — nothing leaves it."
        case .free, .trial:
            return "Licensed on this Mac."
        }
    }

    // MARK: - Hero

    /// Eyebrow, headline, one supporting line — on a whisper of accent so the
    /// sheet reads as a moment, not another settings pane.
    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("SEAL PRO")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(.secondary)
                }
                Text(headline)
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.4)
                Text(subline)
                    .font(Theme.body)
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)

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
        .padding(24)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.07), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var headline: String {
        if let highlighted { return highlighted.heroLine }
        switch entitlements.entitlement {
        case .free: return "Leave the meeting finished."
        case .trial: return "You're trying all of Pro."
        case .pro, .lifetime: return "This Mac has Seal Pro."
        }
    }

    private var subline: String {
        if highlighted != nil {
            return "That's a Seal Pro feature — and it brings the rest of the professional finish with it. All on your Mac."
        }
        switch entitlements.entitlement {
        case .free:
            return "Everything you use today stays free. Pro adds the assistant that turns a transcript into finished work — names on voices, answers, follow-ups, tracked action items."
        case .trial:
            return "Keep it with a license that's yours forever — no subscription, no account."
        case .pro, .lifetime:
            return "Thank you for backing an app that never phones home."
        }
    }

    // MARK: - Features

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 14, alignment: .topLeading),
         GridItem(.flexible(), alignment: .topLeading)]
    }

    /// Two scannable columns with meaningful icons — the tapped feature leads
    /// and carries a soft accent wash so the eye lands where the intent was.
    private var featureGrid: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 6) {
            ForEach(orderedFeatures) { feature in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 17, alignment: .center)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.displayName)
                            .font(Theme.bodyMedium)
                        Text(feature.blurb)
                            .font(Theme.sub)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(feature == highlighted ? Theme.accent.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(feature == highlighted ? Theme.accent.opacity(0.35) : .clear,
                                  lineWidth: 1))
            }
        }
    }

    /// The tapped feature leads; the rest follow in canonical order.
    private var orderedFeatures: [ProFeature] {
        guard let highlighted else { return ProFeature.allCases }
        return [highlighted] + ProFeature.allCases.filter { $0 != highlighted }
    }

    // MARK: - Footer (differentiators + price + actions per state)

    @ViewBuilder
    private var footer: some View {
        switch entitlements.entitlement {
        case .pro, .lifetime:
            HStack {
                valueStrip
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.linearPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        case .free, .trial:
            VStack(alignment: .leading, spacing: 14) {
                valueStrip
                priceRow
                if let days = entitlements.trialDaysLeft {
                    Text("Pro trial — \(days) day\(days == 1 ? "" : "s") left. Everything you make is yours either way.")
                        .font(Theme.sub)
                        .foregroundStyle(.secondary)
                }
                if enteringKey { keyEntry }
                actions
                Text("One license, two Macs · 30-day money-back guarantee. Checked once at activation — Seal never phones home.")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The three honest reasons Seal is different, in one quiet line. This is
    /// the sale: everyone else is a subscription to someone else's server.
    private var valueStrip: some View {
        HStack(spacing: 0) {
            valueItem("banknote", "Pay once — it's yours")
            valueItem("lock", "Everything stays on your Mac")
            valueItem("checkmark.seal", "The free core stays free")
        }
    }

    private func valueItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(Theme.metaMedium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(Pricing.earlyBird)
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.3)
                    Text(Pricing.regular)
                        .font(Theme.body)
                        .strikethrough()
                        .foregroundStyle(.tertiary)
                    Text("EARLY-BIRD")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.amber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(Theme.amber.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                Text("One-time. Yours forever, with a year of updates — \(Pricing.renewal)/yr later only if you want newer features.")
                    .font(Theme.sub)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Straight to the live Freemius checkout; the pricing page (which also
    /// sells Lifetime) only if the store ids are ever cleared.
    private var buyURL: URL { SealStore.checkoutPro ?? Pricing.pricingURL }

    private var actions: some View {
        HStack(spacing: 8) {
            if entitlements.trialAvailable {
                Button("Try Pro free for \(Pricing.trialDays) days") {
                    entitlements.startTrial()
                    dismiss()
                }
                .buttonStyle(.linearPrimary)
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                Button("Buy Seal Pro") { NSWorkspace.shared.open(buyURL) }
                    .buttonStyle(.linearQuiet)
            } else {
                Button("Buy Seal Pro — \(Pricing.earlyBird)") { NSWorkspace.shared.open(buyURL) }
                    .buttonStyle(.linearPrimary)
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
            }
            Spacer()
            Button(enteringKey ? "Hide key entry" : "Have a license key?") {
                withAnimation(.easeOut(duration: 0.15)) { enteringKey.toggle() }
            }
            .buttonStyle(.plain)
            .font(Theme.sub)
            .foregroundStyle(.secondary)
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
                // Not a silent dismiss: the person just paid — land the moment.
                withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                    justActivated = true
                }
            } catch {
                activationError = (error as? LicenseError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
