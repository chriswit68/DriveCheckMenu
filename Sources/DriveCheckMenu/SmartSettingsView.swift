import SwiftUI
import DriveCheckMenuCore

struct SmartSettingsView: View {
    @ObservedObject var state: AppState

    @State private var draftThresholds = HealthThresholds()
    @State private var pathOverride = ""
    @State private var selectedDriveID: String?

    var body: some View {
        Form {
            Section("smartctl") {
                if let path = state.effectiveSmartctlPath {
                    LabeledContent("Status") {
                        HStack(spacing: 7) {
                            StatusDot(level: .ok)
                            Text("Gefunden")
                        }
                    }
                    LabeledContent("Pfad", value: path)
                    LabeledContent("Version", value: state.smartctlVersion ?? "unbekannt")
                } else {
                    Label("smartctl nicht gefunden", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Die App nutzt dann den Basisstatus von diskutil. Für Temperatur, Verschleiß und Fehlerzähler installiere smartmontools, z. B. mit \"brew install smartmontools\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Eigener Pfad") {
                    HStack(spacing: 8) {
                        TextField("/opt/homebrew/bin/smartctl", text: $pathOverride)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button("Übernehmen") {
                            state.setSmartctlPathOverride(pathOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pathOverride)
                        }
                    }
                }

                Toggle("Detaillierte SMART-Werte via smartctl", isOn: Binding(
                    get: { state.settings.useSmartctl },
                    set: { state.setUseSmartctl($0) }
                ))

                Button("Erneut erkennen") {
                    state.detectSmartctl()
                    state.refresh()
                }
            }

            Section("Schwellwerte") {
                LabeledContent("Temperaturwarnung") {
                    HStack(spacing: 6) {
                        TextField("", value: $draftThresholds.temperatureWarning, format: .number.precision(.fractionLength(0)))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("°C").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Temperatur kritisch") {
                    HStack(spacing: 6) {
                        TextField("", value: $draftThresholds.temperatureCritical, format: .number.precision(.fractionLength(0)))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("°C").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Verschleißwarnung") {
                    HStack(spacing: 6) {
                        TextField("", value: $draftThresholds.wearWarning, format: .number.precision(.fractionLength(0)))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Verschleiß kritisch") {
                    HStack(spacing: 6) {
                        TextField("", value: $draftThresholds.wearCritical, format: .number.precision(.fractionLength(0)))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("%").foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Gerätelimits von smartctl werden zusätzlich berücksichtigt, sofern vorhanden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Zurücksetzen") { draftThresholds = .default }
                    Button("Übernehmen") {
                        state.setThresholds(draftThresholds)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftThresholds == state.settings.thresholds)
                }
            }

            Section("SMART-Übersicht") {
                let drives = monitoredConnectedDrives
                if drives.isEmpty {
                    Text("Keine überwachten, verbundenen Laufwerke.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(drives) { status in
                        HStack(spacing: 8) {
                            StatusDot(level: status.health)
                            Text(status.drive.displayName)
                            Spacer()
                            Text(status.shortStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let source = status.smart?.source {
                                Text(source == .smartctl ? "smartctl" : "diskutil")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            Section("SMART-Kurztest") {
                let drives = monitoredConnectedDrives
                if drives.isEmpty {
                    Text("Für einen Selbsttest muss mindestens ein Laufwerk überwacht und verbunden sein.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Laufwerk", selection: $selectedDriveID) {
                        ForEach(drives) { status in
                            Text(status.drive.displayName).tag(Optional(status.id))
                        }
                    }

                    if let status = selectedDriveStatus {
                        if let test = state.selfTests.state(forKey: status.id) {
                            if test.running {
                                if let remaining = test.percentRemaining {
                                    ProgressView(value: max(0, min(1, (100 - remaining) / 100)))
                                    Text("\(test.message) – noch \(Format.number(remaining)) %")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                    Text(test.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if test.requiresAdmin {
                                Text(test.message)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Button("Mit Administratorrechten starten …") {
                                    state.startSelfTestWithAdministrator(for: status)
                                }
                            } else if !test.message.isEmpty {
                                Text("Letztes Ergebnis: \(test.message)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Button("Kurztest starten") {
                                state.startSelfTest(for: status)
                            }
                            .disabled(state.selfTests.isRunning(forKey: status.id))

                            if let test = state.selfTests.state(forKey: status.id), test.running {
                                ProgressView().controlSize(.small)
                            }
                        }

                        Text("Der SMART-Kurztest ist ungefährlich und dauert je nach Laufwerk etwa ein bis zwei Minuten. Währenddessen kann die App normal weiterlaufen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draftThresholds = state.settings.thresholds
            pathOverride = state.settings.smartctlPathOverride ?? ""
            selectDefaultDrive()
            if state.snapshot == nil { state.refresh() }
        }
        .onChange(of: state.settings.thresholds) { _, newValue in
            draftThresholds = newValue
        }
        .onChange(of: state.settings.smartctlPathOverride) { _, newValue in
            pathOverride = newValue ?? ""
        }
        .onChange(of: state.snapshot?.date) { _, _ in
            selectDefaultDrive()
        }
    }

    private var monitoredConnectedDrives: [DriveStatus] {
        (state.snapshot?.drives ?? []).filter { $0.isMonitored && $0.isConnected }
    }

    private var selectedDriveStatus: DriveStatus? {
        guard let selectedDriveID else { return nil }
        return monitoredConnectedDrives.first { $0.id == selectedDriveID }
    }

    private func selectDefaultDrive() {
        let ids = monitoredConnectedDrives.map(\.id)
        if let selectedDriveID, ids.contains(selectedDriveID) { return }
        selectedDriveID = ids.first
    }
}
