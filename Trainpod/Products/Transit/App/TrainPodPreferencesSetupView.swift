import SwiftUI

// Only newly claimed devices enter this flow. Existing bindings are unaffected.
// Keep progress per physical ID so relaunching or switching devices cannot lose it.
enum TrainPodSetupPreferences {
    static func key(_ field: String, _ id: String) -> String { "setup.preferences.\(id).\(field)" }
    static func begin(for id: String) {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: key("pending", id)) {
            defaults.set(0, forKey: key("step", id))
            defaults.set(TransitAgency.selected.rawValue, forKey: key("city", id))
            defaults.set(DeviceDisplayMode.Mode.standard.rawValue, forKey: key("style", id))
        }
        defaults.set(true, forKey: key("pending", id))
    }
}

struct TrainPodConfiguredContent<Content: View>: View {
    let deviceId: String
    @AppStorage private var pending: Bool
    private let content: Content

    init(deviceId: String, @ViewBuilder content: () -> Content) {
        self.deviceId = deviceId
        _pending = AppStorage(wrappedValue: false, TrainPodSetupPreferences.key("pending", deviceId))
        self.content = content()
    }
    var body: some View {
        if pending {
            TrainPodPreferencesSetupView(deviceId: deviceId) { pending = false }
        } else {
            content
        }
    }
}

struct TrainPodPreferencesSetupView: View {
    let deviceId: String
    let onComplete: () -> Void
    @AppStorage private var step: Int
    @AppStorage private var city: String
    @AppStorage private var style: String
    @ObservedObject private var displayMode = BLERuntime.shared.displayMode
    @ObservedObject private var bluetooth = BLERuntime.shared.bluetooth
    @ObservedObject private var bridge = BLERuntime.shared.bridge
    @State private var finishing = false

    init(deviceId: String, onComplete: @escaping () -> Void) {
        self.deviceId = deviceId
        self.onComplete = onComplete
        _step = AppStorage(wrappedValue: 0, TrainPodSetupPreferences.key("step", deviceId))
        _city = AppStorage(wrappedValue: TransitAgency.selected.rawValue, TrainPodSetupPreferences.key("city", deviceId))
        _style = AppStorage(wrappedValue: DeviceDisplayMode.Mode.standard.rawValue, TrainPodSetupPreferences.key("style", deviceId))
    }
    private var agency: TransitAgency { TransitAgency(rawValue: city) ?? .cta }
    private var mode: DeviceDisplayMode.Mode { DeviceDisplayMode.Mode(rawValue: style) ?? .standard }
    private var canFinish: Bool {
        bluetooth.connectedDeviceId == deviceId && displayMode.canSend && displayMode.confirmed != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 8) {
                    ForEach(0..<2) { index in
                        Capsule().fill(index <= step ? Color.primary : Color.secondary.opacity(0.2))
                            .frame(width: 32, height: 4)
                    }
                    Spacer()
                    Text("\(step == 0 ? 1 : 2) of 2").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Setup step \(step == 0 ? 1 : 2) of 2")
                if step == 0 { cityPage } else { stylePage }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) { actions }
        .onChange(of: displayMode.busy) { _, busy in
            guard finishing, !busy else { return }
            finishing = false
            if !displayMode.failed && displayMode.confirmed == mode && bluetooth.connectedDeviceId == deviceId {
                onComplete()
            }
        }
    }

    private var cityPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Your city, at a glance.", subtitle: "Choose where you ride. TrainPod finds nearby stations using your iPhone’s location.")
            VStack(spacing: 10) {
                ForEach(TransitAgency.allCases) { system in
                    Button { city = system.rawValue } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "tram.fill")
                                .frame(width: 44, height: 44)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(system.cityName).font(.headline)
                                Text(system.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: city == system.rawValue ? "checkmark.circle.fill" : "circle")
                        }
                        .foregroundStyle(.primary)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(city == system.rawValue ? Color.primary : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(city == system.rawValue ? .isSelected : [])
                }
            }
            HStack(spacing: 16) {
                VStack(spacing: 0) {
                    Circle().strokeBorder(lineWidth: 3).frame(width: 14, height: 14)
                    Rectangle().frame(width: 3, height: 26)
                    Circle().strokeBorder(lineWidth: 3).frame(width: 14, height: 14)
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Up to \(LiveTransitFormatter.maximumStations) nearby stations").font(.headline)
                    Text("One station on screen at a time. Double-press the TrainPod button to switch stations.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if agency == .mbta {
                Text("Data provided by the Massachusetts Department of Transportation / MBTA.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stylePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Choose your view.", subtitle: "The same nearby stations. A little more detail, or more arrivals at once.")
            Picker("Display style", selection: $style) {
                ForEach(DeviceDisplayMode.Mode.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(finishing)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mode == .compact ? "6" : "3").font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text("arrivals visible").font(.title3)
                }
                Text(mode == .compact
                     ? "Two columns, read left to right, then down. ETA, line color, and line name."
                     : "Three full-width rows with ETA, line color, line name, and destination.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ThemePreview(theme: DeviceTheme.defaultTheme, compact: mode == .compact,
                             station: example.station, direction: example.direction,
                             line: example.line, routeColor: example.color, destination: example.destination)
                Text("Example only · times shown in minutes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            Text("You can change your city from Main and your display style in Customize anytime.")
                .font(.subheadline).foregroundStyle(.secondary)
            if displayMode.busy {
                ProgressView(displayMode.status ?? "Connecting to TrainPod…")
            } else if displayMode.failed, let status = displayMode.status {
                Text(status).font(.subheadline).foregroundStyle(.red)
            }
            if !canFinish && !displayMode.busy {
                Text("Keep TrainPod powered on and nearby. Bluetooth stays available until setup is finished. Reconnect to continue saving your style.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(bluetooth.notificationsReady ? "Read saved style" : "Reconnect TrainPod") {
                    if bluetooth.notificationsReady { displayMode.read() }
                    else { bluetooth.scanAndConnect() }
                }
                .disabled(bluetooth.notificationsReady && !displayMode.canSend)
            }
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
    }
    private var actions: some View {
        VStack(spacing: 12) {
            Button(step == 0 ? "Continue" : finishing ? "Saving…" : "Start using TrainPod") {
                if step == 0 {
                    UserDefaults.standard.set(agency.rawValue, forKey: TransitAgency.preferenceKey)
                    step = 1
                } else {
                    displayMode.selected = mode
                    finishing = true
                    displayMode.save(finishingSetup: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(step == 0 ? bridge.isSending : (!canFinish || finishing))
            if step != 0 {
                Button("Back") { step = 0 }.disabled(finishing)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .tint(.primary)
    }

    private var example: (station: String, direction: String, line: String, color: String, destination: String) {
        switch agency {
        case .cta: return ("Morgan", "West", "GRN", "#009B3A", "Harlem")
        case .mta: return ("23 St", "Uptown", "6", "#00933C", "Pelham Bay")
        case .bart: return ("Embarcadero", "East", "YLW", "#FFE800", "Antioch")
        case .mbta: return ("Park Street", "South", "RED", "#DA291C", "Ashmont")
        }
    }
}
