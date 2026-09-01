import SwiftUI

struct NocturneUploadView: View {
    @ObservedObject var state: NocturneConfig.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(
                header: Text("Health Data Sync"),
                footer: Text(
                    "Trio reads these metrics from Apple Health and uploads them to Nocturne's Health API, which Nightscout has no equivalent for."
                )
            ) {
                Toggle("Enable Nocturne Health Sync", isOn: $state.useNocturne)
                if state.useNocturne {
                    Toggle("Heart Rate", isOn: $state.syncHeartRate)
                    Toggle("Steps", isOn: $state.syncSteps)
                    Toggle("Sleep", isOn: $state.syncSleep)
                }
            }.listRowBackground(Color.chart)

            Section(
                header: Text("Nightscout Data"),
                footer: Text(
                    "Nocturne mirrors the Nightscout API, so Trio can send glucose, treatments, device status, and your therapy profile straight to Nocturne using the connection above — no separate Nightscout connection required. Leave this off if you'd rather keep using the Nightscout connection for that data (it works against a Nocturne URL too)."
                )
            ) {
                Toggle("Upload Nightscout Data", isOn: $state.uploadNightscoutData)
            }.listRowBackground(Color.chart)
        }
        .listSectionSpacing(sectionSpacing)
        .navigationTitle("Upload")
        .navigationBarTitleDisplayMode(.automatic)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }
}
