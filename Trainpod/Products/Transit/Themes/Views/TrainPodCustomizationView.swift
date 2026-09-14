import SwiftUI

struct TrainPodCustomizationView: View {
    @ObservedObject private var model = BLERuntime.shared.uiColor
    @ObservedObject private var bluetooth = BLERuntime.shared.bluetooth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Text("A little color")
                        .font(.title2.weight(.semibold))
                    paletteChoices
                    ThemePreview(theme: model.selectedTheme)
                    Text(model.selectedTheme.name)
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
            Section {
                Toggle("Update device live", isOn: $model.liveEnabled)
                    .tint(.green)
                    .disabled(!bluetooth.notificationsReady && !model.liveEnabled)
            } footer: {
                Text(bluetooth.notificationsReady
                     ? "When on, color changes save to your connected TrainPod as you edit."
                     : "Connect your TrainPod from Main to send colors.")
            }
            Section("Colors") {
                colorPicker("Background", \.background)
                colorPicker("Primary text", \.primaryText)
                colorPicker("Dividers", \.detail)
                colorPicker("Secondary text", \.secondaryText)
                colorPicker("Badges & gauge", \.arrivalBadge)
                colorPicker("Badge & gauge text", \.arrivalBadgeText)
            }
            Section {
                Button { model.push() } label: {
                    Text("Save to TrainPod")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPush)
                saveStatus
            } footer: {
                Text("Your edits stay in the app until saved or sent live. Train line colors stay the same.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var paletteChoices: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 3 : 6), spacing: 16) {
            ForEach(model.themes.prefix(6)) { theme in
                Button { model.selectedThemeID = theme.id } label: {
                    Circle()
                        .fill(DeviceTheme.color(theme.background).gradient)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if model.selectedThemeID == theme.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.bold))
                                    .foregroundStyle(DeviceTheme.color(theme.primaryText))
                            }
                        }
                        .padding(4)
                        .overlay(Circle().strokeBorder(model.selectedThemeID == theme.id ? Color.primary : .clear, lineWidth: 2))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.name)
                .accessibilityAddTraits(model.selectedThemeID == theme.id ? .isSelected : [])
            }
        }
    }

    private func colorPicker(_ title: String, _ keyPath: WritableKeyPath<DeviceTheme, String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { DeviceTheme.color(model.selectedTheme[keyPath: keyPath]) },
            set: { model.setSelectedColor($0, at: keyPath) }
        ), supportsOpacity: false)
        .padding(.vertical, 3)
    }

    @ViewBuilder private var saveStatus: some View {
        switch model.pushState {
        case .idle:
            if model.liveEnabled {
                Label("Live updates on", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            }
        case .sending:
            ProgressView("Saving to TrainPod…")
        case .success:
            Label("Saved on TrainPod", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
        }
    }
}
