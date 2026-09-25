import SwiftUI

struct ThemePreview: View {
    let theme: DeviceTheme
    var compact = false
    var station = "Morgan"
    var direction = "East"
    var line = "GRN"
    var routeColor = "#009B3A"
    var destination = "Harlem"
    private let times = [4, 6, 9, 12, 15, 18]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(station).fontWeight(.semibold).foregroundStyle(DeviceTheme.color(theme.primaryText))
                Spacer()
                Text(direction).foregroundStyle(DeviceTheme.color(theme.secondaryText))
            }
            Rectangle().fill(DeviceTheme.color(theme.detail)).frame(height: 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: compact ? 2 : 1), spacing: 10) {
                ForEach(0..<(compact ? 6 : 3), id: \.self) { index in
                    arrival(time: times[index])
                }
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
        .accessibilityLabel("Local \(compact ? "compact" : "standard") preview: \(theme.name)")
    }

    private func arrival(time: Int) -> some View {
        HStack(spacing: compact ? 6 : 9) {
            Text("\(time)").font(.title2.monospacedDigit().bold())
                .foregroundStyle(DeviceTheme.color(theme.arrivalBadgeText))
                .frame(width: compact ? 42 : 48, height: 34)
                .background(DeviceTheme.color(theme.arrivalBadge), in: Capsule())
            // Fixed example transit identity; themes never change route squares.
            RoundedRectangle(cornerRadius: 4).fill(DeviceTheme.color(routeColor)).frame(width: 18, height: 18)
            Text(line).fontWeight(.semibold).foregroundStyle(DeviceTheme.color(theme.primaryText))
                .lineLimit(1).minimumScaleFactor(0.65)
            Spacer(minLength: 0)
            if !compact {
                Text(destination).foregroundStyle(DeviceTheme.color(theme.secondaryText))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
