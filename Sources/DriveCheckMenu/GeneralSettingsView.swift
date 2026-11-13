import SwiftUI
import DriveCheckMenuCore

struct GeneralSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Start") {
                Toggle("Beim Anmelden automatisch starten", isOn: Binding(
                    get: { state.loginItemEnabled },
                    set: { state.setLaunchAtLogin($0) }
                ))

                HStack(spacing: 6) {
                    StatusDot(level: loginStatusLevel)
                    Text(state.loginItemStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = state.loginItemError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Für einen zuverlässigen Login-Start sollte die App in /Applications liegen. macOS kann die Freigabe in den Systemeinstellungen verlangen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menüleiste") {
                LabeledContent("Menüleistensymbol") {
                    HStack(spacing: 7) {
                        StatusDot(level: state.menuBarItemVisible ? .ok : .problem)
                        Text(state.menuBarItemVisible ? "Sichtbar" : "Nicht sichtbar")
                    }
                }

                Text("Seit macOS 26 (Tahoe) muss eine App unter „Systemeinstellungen → Menüleiste → In der Menüleiste erlauben“ freigegeben werden, damit ihr Symbol erscheint. Ohne Freigabe läuft die App, bleibt aber unsichtbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Menüleisten-Einstellungen öffnen …") {
                    MenuBarPermission.openSettings()
                }
            }

            Section("Überwachung") {
                Picker("Prüfintervall", selection: Binding(
                    get: { state.settings.intervalSeconds },
                    set: { state.setInterval($0) }
                )) {
                    ForEach(CheckInterval.allCases) { interval in
                        Text(interval.label).tag(interval.rawValue)
                    }
                }

                Toggle("Bei Statusänderungen benachrichtigen", isOn: Binding(
                    get: { state.settings.notifyOnChange },
                    set: { state.setNotifyOnChange($0) }
                ))

                Text("Benachrichtigungen werden nur gesendet, wenn ein überwachtes Gerät in den Problemzustand wechselt oder sich wieder erholt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Gesamtstatus") {
                    HStack(spacing: 7) {
                        StatusDot(level: snapshot?.overall ?? .ok)
                        Text(snapshot?.overallSummary ?? "Status wird ermittelt …")
                    }
                }
                LabeledContent("Letzte Prüfung", value: lastCheckText)
                LabeledContent("Überwachte Laufwerke", value: "\(snapshot?.monitoredDriveCount ?? 0)")
                LabeledContent("Überwachte RAID-Sets", value: "\(snapshot?.monitoredRaidCount ?? 0)")

                HStack(spacing: 10) {
                    Button("Jetzt prüfen") { state.refresh() }
                    if state.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if let simulation = state.simulationMode {
                Section("Simulation") {
                    Label("Aktiver Modus: \(simulation.rawValue)", systemImage: "testtube.2")
                        .foregroundStyle(.orange)
                    Text("Die App wurde mit dem Schalter --simulate=\(simulation.rawValue) gestartet. Die echten Statuswerte werden nur zur Anzeige überschrieben.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            state.refreshLoginItemState()
            if state.snapshot == nil { state.refresh() }
        }
    }

    private var snapshot: MonitorSnapshot? { state.snapshot }

    private var loginStatusLevel: HealthLevel {
        if !LoginItem.isSupported { return .warning }
        return state.loginItemEnabled ? .ok : .unknown
    }

    private var lastCheckText: String {
        guard let date = snapshot?.date else { return "–" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
