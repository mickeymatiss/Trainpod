import SwiftUI

struct DeviceLiveColorSection: View {
    @ObservedObject var model: DeviceUIColor
    @ObservedObject var bluetooth: BluetoothService
    @State private var role = LiveColorRole.background

    private enum LiveColorRole: String, CaseIterable, Identifiable {
        case background = "Background"
        case primary = "Primary text"
        case detail = "Divider / detail"
        case secondary = "Secondary text"
        case badge = "Badges & gauge"
        case badgeText = "Badge & gauge text"
        var id: String { rawValue }
        var keyPath: WritableKeyPath<DeviceTheme, String> {
            switch self {
            case .background: return \.background
            case .primary: return \.primaryText
            case .detail: return \.detail
            case .secondary: return \.secondaryText
            case .badge: return \.arrivalBadge
            case .badgeText: return \.arrivalBadgeText
            }
        }
    }

    var body: some View {
        Section {
            Toggle("Update device live", isOn: $model.liveEnabled)
                .disabled(!bluetooth.notificationsReady && !model.liveEnabled)
            Text(model.selectedTheme.name).font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(LiveColorRole.allCases) { item in
                    Button { role = item } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(DeviceTheme.color(model.selectedTheme[keyPath: item.keyPath]))
                                .frame(height: 38)
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(role == item ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: role == item ? 3 : 1))
                            Text(item.rawValue).font(.caption).foregroundStyle(.primary)
                                .lineLimit(2).frame(height: 30)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.rawValue)
                    .accessibilityAddTraits(role == item ? .isSelected : [])
                }
            }
            ThemePreview(theme: model.selectedTheme)
            ColorPicker(role.rawValue, selection: Binding(
                get: { DeviceTheme.color(model.selectedTheme[keyPath: role.keyPath]) },
                set: { model.setSelectedColor($0, at: role.keyPath) }
            ), supportsOpacity: false)
            Text("Tap the color well for Grid, Spectrum, or Sliders.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.selectedTheme[keyPath: role.keyPath]).font(.caption.monospaced())
            if model.liveEnabled {
                Label(model.pushState == .sending ? "Updating device…" : "Live updates on", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            } else {
                Text("Live updates off — adjustments stay in the app.").foregroundStyle(.secondary)
            }
            if case .failed(let message) = model.pushState {
                Text(message).foregroundStyle(.red)
            }
        } header: {
            Text("Live Color")
        } footer: {
            Text("Hold the device button for 2 seconds to open BLE for 60 seconds. Live updates save the latest colors on the device. Live mode turns off on disconnect; turn it on again when ready.")
        }
    }

}
