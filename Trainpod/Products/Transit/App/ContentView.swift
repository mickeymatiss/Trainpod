import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                TrainPodHomeView()
            }
            .tabItem { Label("Main", systemImage: "tram.fill") }

            NavigationStack {
                List {
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
    }
}

#Preview {
    ContentView()
}
