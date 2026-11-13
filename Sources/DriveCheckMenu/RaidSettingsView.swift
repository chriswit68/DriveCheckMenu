import SwiftUI
import DriveCheckMenuCore

struct RaidSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(
                "Zu überwachende RAID-Verbünde",
                subtitle: "AppleRAID-Sets werden inklusive Mitgliedsstatus und Rebuild-Fortschritt überwacht. Degradierte oder offline gesetzte Verbünde lösen einen Alarm aus."
            )

            HStack(spacing: 8) {
                Button("Alle auswählen") { state.setAllRaidsMonitored(true) }
                Button("Auswahl aufheben") { state.setAllRaidsMonitored(false) }
                Spacer()
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button("Aktualisieren") { state.refresh() }
            }

            if raids.isEmpty {
                ContentUnavailableView(
                    "Keine RAID-Verbünde gefunden",
                    systemImage: "externaldrive",
                    description: Text("In macOS konfigurierte AppleRAID-Sets erscheinen hier automatisch.")
                )
            } else {
                List {
                    ForEach(raids) { status in
                        row(for: status)
                    }
                }
                .listStyle(.inset)
            }

            Text("\(raids.filter(\.isMonitored).count) von \(raids.count) RAID-Sets ausgewählt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            if state.snapshot == nil { state.refresh() }
        }
    }

    private var raids: [RaidStatus] {
        state.snapshot?.raids ?? []
    }

    private func row(for status: RaidStatus) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { state.isMonitored(status.raid) },
                set: { state.setRaidMonitored(status.raid, monitored: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            StatusDot(level: status.health)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.raid.displayName)
                    .fontWeight(.medium)
                Text(detailLine(for: status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !status.raid.members.isEmpty {
                    Text(status.raid.members.map { "\($0.bsdName): \($0.status)" }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

    private func detailLine(for status: RaidStatus) -> String {
        if !status.isConnected {
            return "Nicht verfügbar"
        }
        return [
            status.raid.levelText,
            status.raid.sizeText,
            "Status: \(status.raid.status)",
            "/dev/\(status.raid.bsdName)"
        ].joined(separator: " · ")
    }
}
