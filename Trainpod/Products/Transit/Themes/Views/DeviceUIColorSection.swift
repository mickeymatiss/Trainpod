import SwiftUI

struct DeviceUIColorSection: View {
    @ObservedObject var model: DeviceUIColor
    @ObservedObject var bluetooth: BluetoothService

    var body: some View {
        Section {
            ScrollView(.horizontal) {
                LazyHGrid(rows: [GridItem(.fixed(94)), GridItem(.fixed(94))], spacing: 12) {
                    ForEach(model.themes) { theme in
                        Button { model.selectedThemeID = theme.id } label: {
                            themeCard(theme)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.name)
                        .accessibilityAddTraits(model.selectedThemeID == theme.id ? .isSelected : [])
                    }
                }
                .padding(3)
            }
            .scrollIndicators(.visible)
            ThemePreview(theme: model.selectedTheme)
            TextField("Theme name", text: Binding(
                get: { model.selectedTheme.name },
                set: { model.renameSelectedTheme($0) }
            ))
            .accessibilityLabel("Theme name")
            customPicker("Background", \.background)
            customPicker("Primary text", \.primaryText)
            customPicker("Divider / detail", \.detail)
            customPicker("Secondary text", \.secondaryText)
            customPicker("Badges & gauge", \.arrivalBadge)
            customPicker("Badge & gauge text", \.arrivalBadgeText)
            LabeledContent("Selected", value: model.selectedTheme.name)
            if let confirmed = model.deviceTheme {
                LabeledContent("Last confirmed by device", value: confirmed.name)
            }
            Button("Push to Device") { model.push() }
                .disabled(!model.canPush)
            switch model.pushState {
            case .idle:
                Text("Preview locally, then push when ready.").foregroundStyle(.secondary)
            case .sending:
                ProgressView("Waiting for device confirmation…")
            case .success:
                Label("Theme saved on device", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        } header: {
            Text("Device themes")
        } footer: {
            Text("Hold the device button for 2 seconds to open BLE for 60 seconds. Themes stay saved across restarts. Route colors follow transit data.")
        }
    }

    private func customPicker(_ title: String, _ keyPath: WritableKeyPath<DeviceTheme, String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { DeviceTheme.color(model.selectedTheme[keyPath: keyPath]) },
            set: { model.setSelectedColor($0, at: keyPath) }
        ), supportsOpacity: false)
    }

    private func themeCard(_ theme: DeviceTheme) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("4").font(.headline.monospacedDigit())
                    .foregroundStyle(DeviceTheme.color(theme.arrivalBadgeText))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(DeviceTheme.color(theme.arrivalBadge), in: Capsule())
                Text("Aa").font(.headline).foregroundStyle(DeviceTheme.color(theme.primaryText))
                Spacer(minLength: 0)
                if model.selectedThemeID == theme.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DeviceTheme.color(theme.primaryText))
                }
            }
            Rectangle().fill(DeviceTheme.color(theme.detail)).frame(height: 2)
            Text(theme.name).font(.caption.weight(.semibold))
                .foregroundStyle(DeviceTheme.color(theme.primaryText))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(width: 132, height: 94)
        .background(DeviceTheme.color(theme.background), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(model.selectedThemeID == theme.id ? Color.primary : Color.clear, lineWidth: 2))
    }
}
