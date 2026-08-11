import SwiftUI

/// Gates a control behind a Pro feature. Allowed → untouched. Locked → the
/// control keeps its normal look (no grayed-out dead zones), but any click
/// opens the upgrade sheet explaining what it is, instead of running it.
extension View {
    func proGated(_ feature: ProFeature) -> some View {
        modifier(ProGateModifier(feature: feature))
    }
}

private struct ProGateModifier: ViewModifier {
    let feature: ProFeature
    @EnvironmentObject private var entitlements: EntitlementService

    func body(content: Content) -> some View {
        if entitlements.allows(feature) {
            content
        } else {
            content
                .allowsHitTesting(false)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { entitlements.requestUpgrade(for: feature) }
                }
                .help("\(feature.displayName) is part of Seal Pro")
                .accessibilityLabel("\(feature.displayName), Seal Pro feature")
                .accessibilityHint("Opens the Seal Pro upgrade sheet")
        }
    }
}

/// Full-pane lock for surfaces that ARE the feature (the Action Items inbox):
/// explains instead of teasing with dead UI, and one click opens the sheet.
struct ProLockedPane: View {
    let feature: ProFeature
    @EnvironmentObject private var entitlements: EntitlementService

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("\(feature.displayName) is part of Seal Pro")
                .font(Theme.title)
            Text(feature.blurb + ". Runs on your Mac, like everything in Seal.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("See Seal Pro") { entitlements.requestUpgrade(for: feature) }
                .buttonStyle(.linearPrimary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// The small "PRO" mark call sites can place beside a gated control's label.
/// Hidden once the install is licensed or in trial — paid users shouldn't
/// read badges for things they own.
struct ProBadge: View {
    @EnvironmentObject private var entitlements: EntitlementService

    var body: some View {
        if case .free = entitlements.entitlement {
            Text("PRO")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
        }
    }
}
