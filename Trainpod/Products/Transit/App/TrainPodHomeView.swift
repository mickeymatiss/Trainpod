import SwiftUI

struct TrainPodHomeView: View {
    @ObservedObject private var bluetooth = BLERuntime.shared.bluetooth
    @ObservedObject private var refreshHandler = BLERuntime.shared.refreshHandler
    @ObservedObject private var bridge = BLERuntime.shared.bridge
    @AppStorage(TransitAgency.preferenceKey) private var agency = TransitAgency.cta.rawValue
    @AppStorage(MTALocationMode.preferenceKey) private var mtaLocationMode = MTALocationMode.current.rawValue

    private var connecting: Bool {
        bluetooth.connectionState == .scanning || bluetooth.connectionState == .connecting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                citySelector
                customizationLink
                connectionCard
                phoneStatus
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("KeyTrain Connect")
    }

    private var citySelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CITY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("City", selection: $agency) {
                Text("Chicago").tag(TransitAgency.cta.rawValue)
                Text("New York").tag(TransitAgency.mta.rawValue)
            }
            .pickerStyle(.segmented)
            .disabled(bridge.isSending)
        }
    }

    private var customizationLink: some View {
        NavigationLink {
            TrainPodCustomizationView()
        } label: {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    ForEach(DeviceTheme.presets.prefix(6)) { theme in
                        Circle()
                            .fill(DeviceTheme.color(theme.background).gradient)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .accessibilityHidden(true)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Customize").font(.title2.weight(.semibold))
                        Text("Make your TrainPod yours.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right").font(.title3)
                }
            }
            .foregroundStyle(.primary)
            .padding(22)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
            .contentShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("customize")
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Circle().fill(bluetooth.canSend ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 8, height: 8)
                Text(bluetooth.connectionState.title).font(.headline)
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
            }
            if bluetooth.connectionState == .connected {
                Text(bluetooth.connectedDeviceName ?? "TrainPod")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(connecting ? bluetooth.connectionMessage : "Hold your TrainPod’s button for 2 seconds, then connect.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if case .error(let message) = bluetooth.connectionState {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            Button {
                if bluetooth.connectionState == .connected {
                    bluetooth.disconnect()
                } else {
                    bluetooth.scanAndConnect()
                }
            } label: {
                HStack(spacing: 8) {
                    if connecting { ProgressView().tint(Color(.systemBackground)) }
                    Text(connecting ? "Connecting…" : bluetooth.connectionState == .connected ? "Disconnect" : "Connect TrainPod")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(connecting)
        }
        .padding(22)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
    }

    private var phoneStatus: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ON YOUR IPHONE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LabeledContent {
                Text("\(refreshHandler.requestCount)").monospacedDigit()
            } label: {
                Label("Device requests", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            LabeledContent {
                if let date = refreshHandler.lastRequest {
                    Text(date, style: .time).monospacedDigit()
                } else {
                    Text("No requests yet")
                }
            } label: {
                Label("Last request", systemImage: "clock")
            }
            if agency == TransitAgency.mta.rawValue, mtaLocationMode != MTALocationMode.current.rawValue {
                Label("Test location: \(mtaLocationMode)", systemImage: "location.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 4)
    }
}
