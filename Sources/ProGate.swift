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
