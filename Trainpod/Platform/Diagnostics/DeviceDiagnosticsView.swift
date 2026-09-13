import SwiftUI

struct DeviceDiagnosticsView: View {
    @ObservedObject var diagnostics: DeviceDiagnostics
    var body: some View {
        List {
            Section {
                Button("Collect Device Diagnostics") { diagnostics.download() }
                    .disabled(diagnostics.busy)
                if diagnostics.busy {
                    ProgressView(value: diagnostics.progress)
                    Button("Cancel Download", role: .cancel) { diagnostics.cancel() }
                }
                Text(diagnostics.status).font(.footnote).foregroundStyle(.secondary)
            }
            RecentDeviceRequestsSection(bluetooth: diagnostics.bluetooth)
            Section("Saved Diagnostics") {
                if diagnostics.files.isEmpty { Text("No saved diagnostics yet.").foregroundStyle(.secondary) }
                ForEach(diagnostics.files) { file in
                    NavigationLink {
                        DiagnosticTextView(file: file)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(file.date.formatted(date: .abbreviated, time: .shortened))
                            Text(file.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: diagnostics.deleteFiles)
            }
        }
        .navigationTitle("Device Diagnostics")
        .onAppear { diagnostics.reloadFiles() }
    }
}
private struct RecentDeviceRequestsSection: View {
    @ObservedObject var bluetooth: BluetoothService
    var body: some View {
        Section {
            if bluetooth.recentDeviceRequests.isEmpty {
                Text("No device requests received this app session.")
                    .foregroundStyle(.secondary)
            }
            ForEach(bluetooth.recentDeviceRequests) { request in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(request.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(request.receivedAt, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let transaction = request.transactionID {
                        Text("Request ID: \(transaction)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("\(request.backgrounded ? "Background" : "Foreground") · \(request.byteCount) bytes")
                        .font(.caption).foregroundStyle(.secondary)
                    if request.ignored {
                        Text("Ignored while reconnect-only test was active")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Recent Device Requests")
        } footer: {
            Text("Last 50 requests received this app session, newest first. Receipt does not confirm that a response was delivered.")
        }
    }
}
private struct DiagnosticTextView: View {
    let file: SavedDiagnostic
    @State private var text = "Loading…"
    @State private var mode = Mode.normal
    private enum Mode: String, CaseIterable { case normal = "Normal", verbose = "Verbose", raw = "Raw JSON" }
    private var shareURL: URL {
        let candidate = mode == .normal ? file.readableURL : mode == .verbose ? file.verboseURL : file.url
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : file.url
    }
    var body: some View {
        VStack {
            if file.url.pathExtension == "json" {
                Picker("Representation", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
            }
        }
        .navigationTitle("Diagnostic Log")
        .toolbar {
            Menu {
                if mode != .raw && file.url.pathExtension == "json" && shareURL == file.url {
                    ShareLink(item: text) { Label("Share readable text", systemImage: "square.and.arrow.up") }
                } else {
                    ShareLink(item: shareURL) { Label("Share current file", systemImage: "square.and.arrow.up") }
                }
                ShareLink(item: file.url) { Label("Share raw export", systemImage: "curlybraces") }
                if FileManager.default.fileExists(atPath: file.readableURL.path) {
                    ShareLink(items: [file.url, file.readableURL, file.verboseURL].filter { FileManager.default.fileExists(atPath: $0.path) }) {
                        Label("Share all representations", systemImage: "doc.on.doc")
                    }
                }
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
        }
        .task(id: mode) {
            do {
                let data = try Data(contentsOf: file.url)
                if mode == .raw || file.url.pathExtension != "json" { text = String(decoding: data, as: UTF8.self) }
                else { text = try DiagnosticInterleave.render(data, verbose: mode == .verbose) }
            }
            catch { text = "Could not open file: \(error.localizedDescription)" }
        }
    }
}
