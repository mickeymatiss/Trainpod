import SwiftUI

struct ThemePreview: View {
    let theme: DeviceTheme
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Morgan").fontWeight(.semibold).foregroundStyle(DeviceTheme.color(theme.primaryText))
                Spacer()
                Text("East").foregroundStyle(DeviceTheme.color(theme.secondaryText))
            }
            Rectangle().fill(DeviceTheme.color(theme.detail)).frame(height: 2)
            HStack(spacing: 9) {
                Text("4").font(.title2.monospacedDigit().bold())
                    .foregroundStyle(DeviceTheme.color(theme.arrivalBadgeText))
                    .frame(width: 48, height: 34)
                    .background(DeviceTheme.color(theme.arrivalBadge), in: Capsule())
                // Fixed example transit identity; themes never change route squares.
                RoundedRectangle(cornerRadius: 4).fill(DeviceTheme.color("#009B3A")).frame(width: 18, height: 18)
                Text("GRN").fontWeight(.semibold).foregroundStyle(DeviceTheme.color(theme.primaryText))
                Spacer(minLength: 0)
                Text("Harlem").foregroundStyle(DeviceTheme.color(theme.secondaryText))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("900").font(.system(size: 17, weight: .bold)).italic()
                Text("ft").font(.system(size: 11))
            }
                .foregroundStyle(DeviceTheme.color(theme.arrivalBadgeText))
                .padding(.bottom, 3)
                .frame(width: 87, height: 22, alignment: .bottom)
                .background(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 6).fill(DeviceTheme.color(theme.arrivalBadge)))
        }
        .padding([.top, .horizontal], 16)
        .background(DeviceTheme.color(theme.background), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Local preview: \(theme.name)")
    }
}
