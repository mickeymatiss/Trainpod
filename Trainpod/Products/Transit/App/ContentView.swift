import SwiftUI

struct ContentView: View {
    @StateObject private var permissions = PermissionSetupState.shared
    @State private var deviceSelectionError: String?
    @ObservedObject private var binding = TrainPodBindingStore.shared
    @ObservedObject private var setup = BLERuntime.shared.setup
    var body: some View {
        Group {
            if binding.bound == nil || setup.showingSuccess {
                TrainPodSetupView(controller: setup)
            } else if showPermissions {
                PermissionSetupView(permissions: permissions) { permissions.refresh() }
            } else if let active = binding.bound {
                TrainPodConfiguredContent(deviceId: active.deviceId) {
                    normalContent
                }
                .id(active.deviceId)
            }
        }
        .task(id: binding.bound == nil) { if binding.bound == nil { setup.start() } }
    }

    private var showPermissions: Bool { permissions.needsSetup }

    private var normalContent: some View {
        TabView {
            NavigationStack {
                TrainPodHomeView()
            }
            .tabItem { Label("Main", systemImage: "tram.fill") }

            NavigationStack {
                List {
                    #if DEBUG
                    Section("Transit reliability") {
                        NavigationLink {
                            ArrivalComparisonView()
                        } label: {
                            Label("Arrival Comparison & Random Test", systemImage: "arrow.left.arrow.right")
                        }
                    }
                    #endif
                    Section {
                        if let active = binding.bound {
                            LabeledContent("Active device") {
                                Text(active.deviceId).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        Button {
                            do { try BLERuntime.shared.setUpAnotherDevice() }
                            catch { deviceSelectionError = error.localizedDescription }
                        } label: {
                            Label("Set up another TrainPod", systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("trainpod-add-device")
                        ForEach(binding.savedBindings, id: \.deviceId) { saved in
                            Button {
                                do { try BLERuntime.shared.useSavedDevice(saved.deviceId) }
                                catch { deviceSelectionError = error.localizedDescription }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Use saved TrainPod", systemImage: "tram")
                                    Text(saved.deviceId).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Devices")
                    } footer: {
                        Text("One TrainPod is active at a time. Adding another keeps this device saved on your iPhone and does not reset it.")
                    }
                    Section("Registration testing") {
                        NavigationLink {
                            DeveloperRegistrationResetView {
                                permissions.refresh()
                            }
                        } label: {
                            Label("Reset device + app registration", systemImage: "arrow.counterclockwise")
                                .foregroundStyle(.red)
                        }
                    }
                    Section("Developer tools") {
                        NavigationLink {
                            NearbyStationsView()
                        } label: {
                            Label("Transit & connection tools", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        NavigationLink {
                            BLETestView()
                        } label: {
                            Label("BLE tests", systemImage: "waveform.path.ecg")
                        }
                        NavigationLink {
                            DeviceDiagnosticsView(diagnostics: BLERuntime.shared.diagnostics)
                        } label: {
                            Label("Device diagnostics", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    Section("Advanced appearance") {
                        NavigationLink {
                            List {
                                DeviceUIColorSection(model: BLERuntime.shared.uiColor, bluetooth: BLERuntime.shared.bluetooth)
                            }
                            .navigationTitle("Saved themes")
                        } label: {
                            Label("All saved themes", systemImage: "paintpalette")
                        }
                    }
                }
                .navigationTitle("Developer")
            }
            .tabItem { Label("Dev", systemImage: "wrench.and.screwdriver") }
        }
        .tint(.primary)
        .alert("Couldn’t switch devices", isPresented: Binding(
            get: { deviceSelectionError != nil },
            set: { if !$0 { deviceSelectionError = nil } }
        )) {
            Button("OK", role: .cancel) { deviceSelectionError = nil }
        } message: {
            Text(deviceSelectionError ?? "Please try again.")
        }
    }
}

#Preview {
    ContentView()
}
