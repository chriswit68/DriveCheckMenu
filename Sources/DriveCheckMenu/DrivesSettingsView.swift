import SwiftUI
import DriveCheckMenuCore

struct DrivesSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(
                "Zu überwachende Massenspeicher",
                subtitle: "SMART-Status der ausgewählten Laufwerke wird regelmäßig geprüft. Nicht verbundene Laufwerke bleiben in der Auswahl und erscheinen als Warnung."
            )

            HStack(spacing: 8) {
                Button("Alle auswählen") { state.setAllDrivesMonitored(true) }
                Button("Auswahl aufheben") { state.setAllDrivesMonitored(false) }
                Spacer()
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button("Aktualisieren") { state.refresh() }
            }

            if drives.isEmpty {
                ContentUnavailableView(
                    "Keine Laufwerke gefunden",
                    systemImage: "internaldrive",
                    description: Text("Angeschlossene physische Laufwerke erscheinen hier automatisch.")
                )
            } else {
                List {
                    ForEach(drives) { status in
                        row(for: status)
                    }
                }
                .listStyle(.inset)
            }

            Text("\(drives.filter(\.isMonitored).count) von \(drives.count) Laufwerken ausgewählt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            if state.snapshot == nil { state.refresh() }
        }
    }

    private var drives: [DriveStatus] {
        state.snapshot?.drives ?? []
    }

    private func row(for status: DriveStatus) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { state.isMonitored(status.drive) },
                set: { state.setDriveMonitored(status.drive, monitored: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            StatusDot(level: status.health)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.drive.displayName)
                    .fontWeight(.medium)
                Text(detailLine(for: status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                HealthBadge(level: status.health)
                Text(status.shortStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .help(status.reasons.joined(separator: "\n"))
    }

    private func detailLine(for status: DriveStatus) -> String {
        if !status.isConnected {
            return "Nicht verbunden"
        }
        var parts = [
            status.drive.sizeText,
            status.drive.protocolName,
            status.drive.locationText,
            status.drive.kindText
        ]
        if let smart = status.smart, smart.source == .diskutil {
            parts.append("SMART-Basisstatus")
        }
        parts.append("/dev/\(status.drive.bsdName)")
        return parts.joined(separator: " · ")
    }
}
