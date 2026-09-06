import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                NearbyStationsView()
            }
            .tabItem {
                Label("Nearby", systemImage: "tram")
            }

            NavigationStack {
                BLETestView()
            }
            .tabItem {
                Label("BLE Test", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }
}

#Preview {
    ContentView()
}
