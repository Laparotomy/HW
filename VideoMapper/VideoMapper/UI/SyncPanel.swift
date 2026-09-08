import SwiftUI

/// Ensemble controls: pick a role, watch the link quality, see who is connected.
struct SyncPanel: View {
    @ObservedObject var controller: ShowController
    @ObservedObject private var sync: SyncSession

    init(controller: ShowController) {
        self.controller = controller
        self._sync = ObservedObject(wrappedValue: controller.sync)
    }

    var body: some View {
        Form {
            Section("This device") {
                Picker("Role", selection: Binding(
                    get: { sync.role },
                    set: { controller.setRole($0) })) {
                    ForEach(SyncRole.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(roleExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Name", value: sync.localName)
            }

            if sync.role == .follower {
                Section("Clock") {
                    LabeledContent("Status") {
                        Label(sync.isSynchronized ? "Locked" : "Measuring…",
                              systemImage: sync.isSynchronized ? "checkmark.circle.fill" : "clock")
                            .foregroundStyle(sync.isSynchronized ? Color.green : Color.secondary)
                    }
                    LabeledContent("Offset", value: String(format: "%+.1f ms", sync.clockOffset * 1000))
                    LabeledContent("Round trip", value: String(format: "%.1f ms", sync.roundTrip * 1000))
                    Text("Offset is the difference between this device's clock and the host's. Round trip indicates link quality — under 30 ms keeps audio inside the range where two speakers still sound like one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if controller.trackMismatch {
                    Section {
                        Label("This device's music file looks different from the host's. Load the same track for tight audio sync.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Connected devices") {
                if sync.peers.isEmpty {
                    Text(sync.role == .solo
                         ? "Choose Host or Join to link devices."
                         : "Looking for devices on the same Wi-Fi network…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sync.peers) { peer in
                        Label(peer.peerID.displayName, systemImage: "iphone")
                    }
                }
            }

            if let error = sync.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var roleExplanation: String {
        switch sync.role {
        case .solo: return "Runs on its own."
        case .host: return "Sends the show and the clock to joined devices. Edits made here appear on every device."
        case .follower: return "Follows a host's clock and layout. The show plays from this device's own media."
        }
    }
}
