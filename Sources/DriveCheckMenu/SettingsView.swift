import SwiftUI
import DriveCheckMenuCore

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsView(state: state)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }

            DrivesSettingsView(state: state)
                .tabItem { Label("Laufwerke", systemImage: "internaldrive") }

            RaidSettingsView(state: state)
                .tabItem { Label("RAID", systemImage: "externaldrive.connected.to.line.below") }

            SmartSettingsView(state: state)
                .tabItem { Label("SMART", systemImage: "waveform.path.ecg") }
        }
        .padding(18)
        .frame(minWidth: 700, minHeight: 540)
    }
}
