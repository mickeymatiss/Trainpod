import SwiftUI

struct TrainPodSetupView: View {
    @ObservedObject var controller: TrainPodSetupController
    @ObservedObject private var binding = TrainPodBindingStore.shared
    @State private var deviceSelectionError: String?
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: controller.showingSuccess ? "checkmark.circle.fill" : "tram.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(controller.showingSuccess ? Color.green : Color.primary)
                Text("Set up TrainPod").font(.title2.weight(.semibold))
                Text(controller.message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("trainpod-setup-status")
                if !controller.showingSuccess {
                    ProgressView()
                    Button("Retry") { controller.start() }
                        .buttonStyle(.bordered)
                    if !binding.savedBindings.isEmpty {
                        Menu("Use a saved TrainPod") {
                            ForEach(binding.savedBindings, id: \.deviceId) { saved in
                                Button(saved.deviceId) {
                                    do { try BLERuntime.shared.useSavedDevice(saved.deviceId) }
                                    catch { deviceSelectionError = error.localizedDescription }
                                }
                            }
                        }
                        .accessibilityIdentifier("trainpod-use-saved-device")
                        Text("Your other TrainPods stay saved on this iPhone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 360)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
            .padding(24)
        }
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
